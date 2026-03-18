#!/usr/bin/env ruby

require 'json'
require 'open3'
require 'fileutils'
require 'securerandom'
require 'net/http'
require 'uri'

if File.exist?('env.rb')
  require './env'
end

$stdout.sync = true

MODE = ENV['MODE'] || 'once'
SOURCE_TEMPLATE = ENV['GIT_SOURCE_TEMPLATE']
DEST_TEMPLATE   = ENV['GIT_DEST_TEMPLATE']

RAW_CONFIG = {
  "mappings" => [
    {
      "source" => {
        "repo" => "$GIT_SOURCE_REPO1",
        "authentication" => false,
        "ref" => {
          "type" => "$GIT_SOURCE_REF_TYPE1",
          "value" => "$GIT_SOURCE_REF_NAME1"
        }
      },
      "destination" => {
        "repo" => "$GIT_DEST_REPO1",
        "branch" => "$GIT_DEST_REF_NAME1",
        "authentication" => true,
      },
      "transform" => {
        "replacements" => [
          {
            "find" => /^(\s*)repoURL:\s+(.+)$/,
            "replace" => "\\1repoURL: http://gitea-http.gitea.svc.cluster.local:3000/local/data-plane.git",
            "regex" => true
          }
        ],
        "exclude_files" => [
          "values-local.yaml"
        ],
        "ignore_paths" => [
          ".git",
          "node_modules"
        ]
      }
    },

    {
      "source" => {
        "repo" => "$GIT_SOURCE_REPO2",
        "authentication" => false,
        "ref" => {
          "type" => "$GIT_SOURCE_REF_TYPE2",
          "value" => "$GIT_SOURCE_REF_NAME2"
        }
      },
      "destination" => {
        "repo" => "$GIT_DEST_REPO2",
        "branch" => "$GIT_DEST_REF_NAME2",
        "authentication" => true,
      },
      "transform" => {
        "replacements" => [],
        "exclude_files" => [ "values-local.yaml" ],
        "ignore_paths" => [ ".git", "node_modules" ]
      }
    },

    {
      "source" => {
        "repo" => "$GIT_SOURCE_REPO3",
        "authentication" => false,
        "ref" => {
          "type" => "$GIT_SOURCE_REF_TYPE3",
          "value" => "$GIT_SOURCE_REF_NAME3"
        }
      },
      "destination" => {
        "repo" => "$GIT_DEST_REPO3",
        "branch" => "$GIT_DEST_REF_NAME3",
        "authentication" => true,
      },
      "transform" => {
        "replacements" => [],
        "exclude_files" => [ "values-local.yaml" ],
        "ignore_paths" => [ ".git", "node_modules" ]
      }
    }
  ]
}

raise "Missing env" unless SOURCE_TEMPLATE && DEST_TEMPLATE

# ------------------------
# utils
# ------------------------

def gitea_enabled?
  ENV['GIT_PROVIDER'] == 'gitea'
end

def gitea_request(method, path, body=nil)
  uri = URI("#{ENV['GITEA_BASE_URL']}#{path}")

  req =
    case method
    when :get  then Net::HTTP::Get.new(uri)
    when :post then Net::HTTP::Post.new(uri)
    else raise "unsupported method"
    end

  req.basic_auth(ENV['GITEA_USERNAME'], ENV['GITEA_PASSWORD'])
  req['Content-Type'] = 'application/json'
  req.body = body.to_json if body

  res = Net::HTTP.start(uri.hostname, uri.port) do |http|
    http.request(req)
  end

  res
end

# cache กันยิงซ้ำ
@gitea_org_cache  = {}
@gitea_repo_cache = {}

def split_repo(full)
  parts = full.split("/")
  raise "Invalid repo format (org/repo): #{full}" unless parts.size == 2
  parts
end

def ensure_org_exists(org)
  return unless gitea_enabled?
  return if @gitea_org_cache[org]

  res = gitea_request(:get, "/api/v1/orgs/#{org}")

  if res.code.to_i == 200
    @gitea_org_cache[org] = true
    return
  end

  puts "Creating org: #{org}"

  res = gitea_request(:post, "/api/v1/orgs", {
    username: org,
    full_name: org
  })

  unless res.code.to_i == 201
    raise "Failed to create org #{org}: #{res.body}"
  end

  @gitea_org_cache[org] = true
end

def ensure_repo_exists(org, repo)
  return unless gitea_enabled?
  key = "#{org}/#{repo}"
  return if @gitea_repo_cache[key]

  res = gitea_request(:get, "/api/v1/repos/#{org}/#{repo}")

  if res.code.to_i == 200
    @gitea_repo_cache[key] = true
    return
  end

  puts "Creating repo: #{org}/#{repo}"

  res = gitea_request(:post, "/api/v1/org/#{org}/repos", {
    name: repo,
    private: false
  })

  unless res.code.to_i == 201
    raise "Failed to create repo #{org}/#{repo}: #{res.body}"
  end

  @gitea_repo_cache[key] = true
end

def resolve_env(value)
  return value unless value.is_a?(String)

  value.gsub(/\$([A-Z0-9_]+)/) do
    env_key = $1
    ENV[env_key] || raise("Missing ENV: #{env_key}")
  end
end

def resolve_config(obj)
  case obj
    when Hash
      obj.transform_values { |v| resolve_config(v) }
    when Array
      obj.map { |v| resolve_config(v) }
    when String
      resolve_env(obj)
    else
      obj
  end
end

def run_cmd(cmd, dir='/tmp')
  puts ">> #{cmd}"
  stdout, stderr, status = Open3.capture3(cmd, chdir: dir)
  puts stdout
  puts stderr
  unless status.success?
    puts stderr
    raise "Command failed: #{cmd}"
  end
end

def build_url(template, repo, use_auth: false, token: nil)
  url = template.gsub("{repo}", repo)

  return url unless use_auth && token

  # inject token for https only
  if url.start_with?("https://")
    url.sub("https://", "https://#{token}@")
  else
    # SSH → ไม่ต้องทำอะไร
    url
  end
end

def text_file?(path)
  return false unless File.file?(path)
  # simple check: skip binary
  File.open(path, "rb") { |f| f.read(1024) }.count("\x00") == 0
end

# ------------------------
# transform
# ------------------------

def apply_replacements(dir, replacements, ignore_paths=[])
  return if replacements.nil? || replacements.empty?

  puts "== applying replacements =="

  Dir.glob("#{dir}/**/*").each do |file|
    next unless text_file?(file)

    # ignore paths
    if ignore_paths.any? { |p| file.include?(p) }
      next
    end

    original_content = File.read(file)
    content = original_content.dup

    replacements.each do |r|
      find = r["find"]
      replace = r["replace"]

      if r["regex"]
        content = content.gsub(find, replace)
      else
        content = content.gsub(find, replace)
      end
    end

    # 🔥 check ว่ามีการเปลี่ยนจริงมั้ย
    if content != original_content
      puts "Replaced in: #{file}"
      File.write(file, content)
    end
  end
end

# ------------------------
# core sync
# ------------------------
def sync_one(mapping)
  work_dir = "/tmp/git-sync-#{SecureRandom.hex(4)}"
  src_tmp  = "/tmp/git-src-#{SecureRandom.hex(4)}"

  FileUtils.rm_rf(work_dir)
  FileUtils.rm_rf(src_tmp)

  src_repo = mapping["source"]["repo"]
  dst_repo = mapping["destination"]["repo"]

  ref_type = mapping["source"]["ref"]["type"]
  ref_val  = mapping["source"]["ref"]["value"]
  dst_branch = mapping["destination"]["branch"]

  source_auth = mapping["source"]["authentication"]
  dest_auth   = mapping["destination"]["authentication"]

  source_token = ENV['GIT_SOURCE_TOKEN']
  dest_token   = ENV['GIT_DEST_TOKEN']

  source_url = build_url(SOURCE_TEMPLATE, src_repo, use_auth: source_auth, token: source_token)
  dest_url   = build_url(DEST_TEMPLATE, dst_repo, use_auth: dest_auth, token: dest_token)

  puts "=== Sync #{src_repo} -> #{dst_repo} ==="

  # ------------------------
  # ensure destination exists (Gitea)
  # ------------------------
  if gitea_enabled?
    org, repo = split_repo(dst_repo)
    ensure_org_exists(org)
    ensure_repo_exists(org, repo)
  end

  # ------------------------
  # 1. clone destination (BASE)
  # ------------------------
  run_cmd("git clone #{dest_url} #{work_dir}")

  # ensure branch
  run_cmd("git checkout #{dst_branch} || git checkout -b #{dst_branch}", work_dir)

  # ------------------------
  # 2. clone source
  # ------------------------
  run_cmd("git clone #{source_url} #{src_tmp}")

  if ref_type == "branch"
    run_cmd("git checkout #{ref_val}", src_tmp)
  elsif ref_type == "tag"
    run_cmd("git checkout tags/#{ref_val}", src_tmp)
  end

  transform = mapping["transform"] || {}

  # ------------------------
  # 3. copy source → destination
  # ------------------------
  puts "== merging source into destination =="

  exclude_files = transform["exclude_files"] || []

  Dir.glob("#{src_tmp}/**/*", File::FNM_DOTMATCH).each do |path|
    next if path.include?(".git")

    rel = path.sub("#{src_tmp}/", "")
    dst = File.join(work_dir, rel)

    if File.directory?(path)
      FileUtils.mkdir_p(dst)
    else
      FileUtils.mkdir_p(File.dirname(dst))

      # 🔥 logic สำคัญ
      if exclude_files.include?(File.basename(rel)) && File.exist?(dst)
        puts "Preserve existing file: #{rel}"
        next
      end

      FileUtils.cp(path, dst)
      puts "Copied: #{rel}"
    end
  end

  # ------------------------
  # 5. apply replacements
  # ------------------------
  apply_replacements(
    work_dir,
    transform["replacements"],
    transform["ignore_paths"] || [".git"]
  )

  # ------------------------
  # 6. commit (ถ้ามี diff)
  # ------------------------
  run_cmd("git config user.email 'git-sync@local'", work_dir)
  run_cmd("git config user.name 'git-sync-bot'", work_dir)
  run_cmd("git add .", work_dir)

  stdout, _, _ = Open3.capture3("git status --porcelain", chdir: work_dir)

  if stdout.strip != ""
    run_cmd("git commit -m 'sync from #{src_repo}'", work_dir)
  else
    puts "Nothing to commit, skip push"
    return
  end

  # ------------------------
  # 7. push กลับ destination
  # ------------------------
  run_cmd("git push origin #{dst_branch}", work_dir)
end

def sync_all
  CONFIG["mappings"].each do |m|
    sync_one(m)
  end
end

# ------------------------
# modes
# ------------------------
CONFIG = resolve_config(RAW_CONFIG)

if MODE == "once"
  sync_all
  exit 0
end

if MODE == "server"
  require 'sinatra'
  require 'json'

  set :bind, '0.0.0.0'
  set :port, 4567

  $running = false

  post '/sync' do
    if $running
      status 409
      return { error: "sync already running" }.to_json
    end

    Thread.new do
      begin
        $running = true
        sync_all
      ensure
        $running = false
      end
    end

    status 202
    { message: "sync started" }.to_json
  end

  get '/' do
    "git-sync running"
  end
end

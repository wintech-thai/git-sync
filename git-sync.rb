#!/usr/bin/env ruby

require 'json'
require 'open3'
require 'fileutils'
require 'securerandom'

if File.exist?('env.rb')
  require './env'
end

$stdout.sync = true

MODE = ENV['MODE'] || 'once'
SOURCE_TEMPLATE = ENV['GIT_SOURCE_TEMPLATE']
DEST_TEMPLATE   = ENV['GIT_DEST_TEMPLATE']

CONFIG = {
  "mappings" => [
    {
      "source" => {
        "repo" => "please-protect-data-plane",
        "authentication" => false,
        "ref" => {
          "type" => "branch",
          "value" => "main"
        }
      },
      "destination" => {
        "repo" => "please-protect-local",
        "branch" => "main",
        "authentication" => true,
      },
      "transform" => {
        "replacements" => [
          {
            "find" => /^repoURL:\s+(.+)$/,
            "replace" => "repoURL: http://gitea-http.gitea.svc.cluster.local/data-plane.git",
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
    }
  ]
}

raise "Missing env" unless SOURCE_TEMPLATE && DEST_TEMPLATE



# ------------------------
# utils
# ------------------------

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

def preserve_files(tmp_dir, dest_url, branch, files)
  return if files.nil? || files.empty?

  dest_tmp = "/tmp/git-preserved-#{SecureRandom.hex(4)}"
  FileUtils.rm_rf(dest_tmp)

  puts "== preserve from dest =="
  run_cmd("git clone --branch #{branch} #{dest_url} #{dest_tmp}")

  files.each do |f|
    src = File.join(dest_tmp, f)
    dst = File.join(tmp_dir, f)

    if File.exist?(src)
      FileUtils.mkdir_p(File.dirname(dst))
      FileUtils.cp(src, dst)
      puts "Preserved #{f}"
    end
  end

  #FileUtils.rm_rf(dest_tmp)
end

def apply_replacements(dir, replacements, ignore_paths=[])
  return if replacements.nil? || replacements.empty?

  puts "== applying replacements =="

  Dir.glob("#{dir}/**/*").each do |file|
    next unless text_file?(file)

    # ignore paths
    if ignore_paths.any? { |p| file.include?(p) }
      next
    end

    content = File.read(file)

    replacements.each do |r|
      find = r["find"]
      replace = r["replace"]

      # support regex
      if r["regex"]
        content = content.gsub(Regexp.new(find), replace)
      else
        content = content.gsub(find, replace)
      end
    end

    File.write(file, content)
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
  # 1. clone destination (BASE)
  # ------------------------
  run_cmd("git clone #{dest_url} #{work_dir}")

  # ensure branch
  run_cmd("git checkout #{dst_branch} || git checkout -b #{dst_branch}", work_dir)

  # ------------------------
  # 2. clone source
  # ------------------------
  run_cmd("git clone --depth 1 #{source_url} #{src_tmp}")

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

  Dir.glob("#{src_tmp}/**/*", File::FNM_DOTMATCH).each do |path|
    next if path.include?(".git")

    rel = path.sub("#{src_tmp}/", "")
    dst = File.join(work_dir, rel)

    if File.directory?(path)
      FileUtils.mkdir_p(dst)
    else
      FileUtils.mkdir_p(File.dirname(dst))
      FileUtils.cp(path, dst)
    end
  end

  # ------------------------
  # 4. preserve files (override กลับ)
  # ------------------------
  preserve_files(
    work_dir,
    dest_url,
    dst_branch,
    transform["exclude_files"]
  )

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

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
        "authentication": false,
        "ref" => {
          "type" => "branch",
          "value" => "main"
        }
      },
      "destination" => {
        "repo" => "please-protect-local",
        "branch" => "main",
        "authentication": true,
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

  dest_tmp = "/tmp/git-dest-#{SecureRandom.hex(4)}"
  FileUtils.rm_rf(dest_tmp)

  puts "== preserve from dest =="
  run_cmd("git clone --depth 1 --branch #{branch} #{dest_url} #{dest_tmp}")

  files.each do |f|
    src = File.join(dest_tmp, f)
    dst = File.join(tmp_dir, f)

    if File.exist?(src)
      FileUtils.mkdir_p(File.dirname(dst))
      FileUtils.cp(src, dst)
      puts "Preserved #{f}"
    end
  end

  FileUtils.rm_rf(dest_tmp)
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
  tmp = "/tmp/git-sync-#{SecureRandom.hex(4)}"
  FileUtils.rm_rf(tmp)

  src_repo = mapping["source"]["repo"]
  dst_repo = mapping["destination"]["repo"]

  ref_type = mapping["source"]["ref"]["type"]
  ref_val  = mapping["source"]["ref"]["value"]
  dst_branch = mapping["destination"]["branch"]

  source_auth = mapping["source"]["authentication"]
  dest_auth   = mapping["destination"]["authentication"]

  source_token = ENV['GIT_SOURCE_TOKEN']
  dest_token   = ENV['GIT_DESTINATION_TOKEN']

  source_url = build_url(
    SOURCE_TEMPLATE,
    src_repo,
    use_auth: source_auth,
    token: source_token
  )

  dest_url = build_url(
    DEST_TEMPLATE,
    dst_repo,
    use_auth: dest_auth,
    token: dest_token
  )

  puts "=== Sync #{src_repo} -> #{dst_repo} ==="

  # clone source
  run_cmd("git clone --depth 1 #{source_url} #{tmp}")

  # checkout
  if ref_type == "branch"
    run_cmd("git checkout #{ref_val}", tmp)
  elsif ref_type == "tag"
    run_cmd("git checkout tags/#{ref_val}", tmp)
  else
    raise "Unknown ref type"
  end

  transform = mapping["transform"] || {}

  # preserve files from dest BEFORE replace
  preserve_files(
    tmp,
    dest_url,
    dst_branch,
    transform["exclude_files"]
  )

  # apply replacements
  apply_replacements(
    tmp,
    transform["replacements"],
    transform["ignore_paths"] || [".git"]
  )

  # push
  run_cmd("git remote add dest #{dest_url}", tmp)
  run_cmd("git push dest HEAD:refs/heads/#{dst_branch} --force", tmp)

  FileUtils.rm_rf(tmp)
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

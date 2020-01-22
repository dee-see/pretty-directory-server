require 'sinatra'
require 'sinatra/config_file'
require 'optparse'
require 'redcarpet'
require 'rouge'
require 'erb'
require 'open3'
require 'rouge/plugins/redcarpet'

class HtmlWithRouge < Redcarpet::Render::HTML
  include Rouge::Plugins::Redcarpet
end

def split_entries(path)
  files = []
  dirs = []
  Dir.entries(path).sort.each do |entry|
    if File.directory?(File.join(path, entry))
      dirs.push(entry)
    else
      files.push(entry)
    end
  end

  [files, dirs]
end

def render_code(code, language, menu_data)
  renderer = Redcarpet::Markdown.new(HtmlWithRouge, no_intra_emphasis: true, tables: true, fenced_code_blocks: true)
  md = renderer.render("```#{language}
#{code}
```")

  erb :code, locals: { code: md, menu_data: menu_data }
end

def render_code_file(path, language, menu_data)
  render_code(File.read(path), language, menu_data)
end

set :bind, '0.0.0.0'
set :logging, true
set :port, 1234
config_file 'config.yml'

server_username = ENV['PDS_BASIC_AUTH_USERNAME']
server_password = ENV['PDS_BASIC_AUTH_PASSWORD']
unless server_username.nil? || server_password.nil?
  use Rack::Auth::Basic, 'Restricted Area' do |username, password|
    username == server_username && password == server_password
  end
end

helpers do
  def url_encode(str)
    ERB::Util.url_encode(str)
  end
end

get '/find_file' do
  dir = params['parent_dir']
  filename = params['filename']

  if dir.nil? || filename.nil?
    halt 400
  else
    root = File.expand_path(settings.directory)
    path = Dir.glob("#{root}/**/#{dir}/**/#{filename}").first
    if path.nil?
      halt 404, 'File does not exist'
    else
      redirect path.gsub(root, '').to_s
    end
  end
end

get '/highlight.css' do
  headers 'Content-Type' => 'text/css'
  Rouge::Themes::Base16.mode(:dark).render(scope: '.highlight')
end

get '/*' do |sub_path|
  root = File.expand_path(settings.directory)
  path = File.join(root, sub_path)
  raw = params['raw'] == 'true'
  diff = params['show_diff'] == 'true'

  halt 400, 'Invalid path' unless path.start_with?(root)

  if File.directory?(path)
    files, dirs = split_entries(path)
    erb :directory_listing, locals: { sub_path: request.path_info, base_dir: root, files: files, dirs: dirs }
  elsif File.exist?(path)
    parent = File.dirname(path)
    relative_parent = parent.gsub(root, '')
    files, _ = split_entries(parent)
    current_file_position = files.index(File.basename(path))
    menu_data = {
      previous: File.join(relative_parent, files[current_file_position - 1]),
      parent: relative_parent.empty? ? '/' : relative_parent,
      next: File.join(relative_parent, files[(current_file_position + 1) % files.length])
    }

    if raw
      content_type 'text/plain'
      send_file path
    elsif diff
      _, o, e, t = Open3.popen3('git', 'log', '-1', '-p', File.basename(path), chdir: File.dirname(path))
      if t.value.exitstatus.zero?
        render_code(o.read, 'diff', menu_data)
      else
        halt 500, "`git diff` error: #{e.read}"
      end
    else
      ext = File.extname(path).downcase
      case ext
      when '.md'
        markdown File.read(path)
      when '.rb'
        render_code_file(path, 'ruby', menu_data)
      when '.yml'
        render_code_file(path, 'yaml', menu_data)
      when '.js'
        render_code_file(path, 'javascript', menu_data)
      when '.png', 'jpg'
        send_file path
      else
        begin
          render_code_file(path, ext[1..-1] || 'txt', menu_data)
        rescue StandardError
          content_type 'text/plain'
          send_file path
        end
      end
    end
  else
    halt 404, 'File does not exist'
  end
end

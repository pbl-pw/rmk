require 'rmk/version'

class Rmk
	def self.normalize_path(path) path.gsub(?\\, ?/).sub(/^[a-z](?=:)/){|ch|ch.upcase} end

	def initialize(srcroot, outroot)
		@rootdir = Rmk::Dir.new Rmk.normalize_path(srcroot), Rmk.normalize_path(outroot)
		::Dir.mkdir outroot unless Dir.exist? outroot
		@rootdir.parse
	end

	def build(*tgts)
	end
end

class Rmk::Rule
	attr_accessor :vars
	def initialize
		vars = {}
	end
end

class Rmk::Dir
	attr_reader :srcroot, :outroot, :path, :full_src_path, :full_out_path
	attr_reader :srcfiles, :outfiles
	attr_reader :vars, :rules, :subdirs
	attr_writer :defaultfile
	protected :defaultfile=

	def initialize(srcroot, outroot, path = '')
		@srcroot, @outroot, @path, @defaultfile = srcroot, outroot, path, nil
		@vars, @rules, @subdirs = {}, {}, {}
		@srcfiles, @outfiles = [], []
		@full_src_path = ::File.join @srcroot, @path, ''
		@full_out_path = ::File.join @outroot, @path, ''
	end

	def add_subdir(path)
		dir = @subdirs[path] = Rmk::Dir.new @srcroot, @outroot, path
		dir.defaultfile = @defaultfile
		dir
	end

	def join_src_path(file) ::File.join @full_src_path, file end

	def join_out_path(file) ::File.join @full_out_path, file end

	def parse
		file = join_src_path 'default.rmk'
		@defaultfile = file if ::File.exist? file
		file = join_out_path 'config.rmk'
		parse_file file if ::File.exist? file
		file = join_src_path 'dir.rmk'
		if ::File.exist? file
			parse_file file
		elsif @defaultfile
			parse_file @defaultfile
		else
			raise "dir parse error: '#{file}' doesn't exist and can't finded any 'default.mk'"
		end
	end

	def parse_file(file)
		lines = IO.readlines file
		lid = 0
		while lid < lines.size
			line, markid = '', lid
			while lid < lines.size
				break if lines[lid].sub!(/(?<!\$)((?:\$\$)*)#.*$/){$1}
				break unless lines[lid].sub!(/(?<!\$)((?:\$\$)*)\$\n/m){$1}
				line += lines[lid]
				lid += 1
			end
			parse_line lid < lines.size ? line + lines[lid] : line, markid
		end
	end

	def parse_line(line, lid)
		match = /^(?<indent>\s*)(?:(?<firstword>\w+)(?:\s*|\s+(?<content>.*)))?$/.match line
		indent, firstword, line = match[:indent], match[:firstword], match[:content]
		return end_last_define unless firstword
		case firstword
		when 'rule'
			raise "#{lid}: rule name invalid" unless line =~ /^\s+(?<name>\w+)\s*$/
			define_rule Regexp.last_match(:name), indent
		when 'buildeach'
		when 'build'
		when 'default'
		when 'include'
		when 'incdir'
			dirs = line.gsub /\$(?:[\$ ]|{\w+})/ do |match|
				case match
				when '$ ' then ?\0
				when '$$' then '$'
				when /\${(?<name>\w+)}/ then @vars[Regexp.last_match :name]
				end
			end
			dirs.gsub! /\s/, ?\n
			dirs.gsub! ?\0, ' '		# restore space
			dirs = dirs.split /\n+/
			raise "#{lid}; must have dir name or matcher" if dirs.empty?
			dirs.each do |dir|
				subs = ::Dir[::File.join @full_src_path, dir, '']
				raise "#{lid}: subdir '#{dir}' doesn't exist" if subs.empty?
				subs.each do |dir|
					dir = dir.sub @full_src_path, ''
					new_thread {add_subdir dir}
				end
			end
			join_threads
		else
			match = /^\s*=\s*(?<value>.*)$/.match line
			raise "#{lid} : ”Ô∑®¥ÌŒÛ" unless match
			define_var firstword, match[:value], indent
		end
	end

	# run in new thread
	# @note not ready
	def new_thread(&cmd) cmd.call end

	# wait all threads
	# @note not ready
	def join_threads; end
end

require 'rmk/version'

class Rmk
	def initialize(srcroot, outroot)
		@rootdir = Rmk::Dir.new srcroot, outroot
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
	attr_reader :srcroot, :outroot, :path
	attr_accessor :srcfiles, :outfiles
	attr_accessor :vars, :rules, :subdirs

	def initialize(srcroot, outroot, path = '', defaultfile = nil)
		@srcroot, @outroot, @path, @defaultfile = srcroot, outroot, path, defaultfile
		@vars, @rules, @subdirs = {}, {}, {}
		@srcfiles, @outfiles = [], []
	end

	def add_subdir(path) @subdirs[path] = Rmk::Dir.new @srcroot, @outroot, path, @defaultfile end

	def join_src_path(file) ::File.join @srcroot, @path, file end

	def join_out_path(file) ::File.join @outroot, @path, file end

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
			lines[lid].sub! /(?<!\$)\#.*$/
			while lines[lid].sub! /(?<!\$)\$$/, ''
				line += lines[lid]
				lid += 1
				break unless lid < lines.size
				lines[lid].sub! /^\s*/, ''
			end
			parse_line line + (lines[lid] || ''), markid
		end
	end

	def parse_line(line, lid)
		line =~ /^(?<indent>\s*)(?<firstword>\w+)?(?<content>.*)$/
		indent, firstword, line = Regexp.last_match(:indent), Regexp.last_match(:firstword), Regexp.last_match(:content)
		return end_last_define unless firstword
		case firstword
		when 'rule'
			raise "#{lid}: rule name invalid" unless line =~ /^\s+(?<name>\w+)\s*$/
			define_rule Regexp.last_match(:name), indent
		when 'buildeach'
		when 'build'
		when 'default'
		when 'include'
			dirs = Dir["#{curdir}/#{}"]
		else
			match = /^\s*=\s*(?<value>.*)$/.match line
			raise "#{lid} : ”Ô∑®¥ÌŒÛ" unless match
			define_var firstword, match[:value], indent
		end
	end
end

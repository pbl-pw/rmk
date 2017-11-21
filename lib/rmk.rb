require 'rmk/version'

class Rmk
end

class Rmk::Dir
	attr_accessor :path
	attr_accessor :srcfiles, :outfiles

	def initialize(path = nil)
		@path = path
		srcfiles, outfiles = [], []
	end
end

class Rmk::File
	attr_reader :dir
end

def Rmk.parse(srcroot, tgtroot = Dir.pwd)
end

def Rmk.parse_line(line, lid)
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

def Rmk.parse_file(file)
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

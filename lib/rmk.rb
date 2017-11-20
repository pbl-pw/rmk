require 'rmk/version'

class Rmk
end

class Rmk::Dir

end

def Rmk.parse(srcroot, tgtroot = Dir.pwd)
end

def Rmk.parse_line(line, lid)
	case line
	when /^(?<indent>\s*)rule\s+(?<name>.*)$/
		raise "#{lid}: rule name invalid" unless Regexp.last_match(:name) =~ /^(?<name>\w+)\s*$/
		rule_def_begin
	when /^buildeach\s+/
	when /^build\s+/
	when /^default\s+/
	when /^include\s+/
	when /^\s*$/
		back_to_mainobj
	else
		match = /^(?<indent>\s*)(?<name>\w+)\s*=\s*(?<value>.*)$/.match line
		raise "#{lid} : Óï·¨´íÎó" unless match
		define_var match[:name], match[:value], match[:indent].empty?
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

require 'rmk/version'

class Rmk
end

def Rmk.parse(srcroot, tgtroot = Dir.pwd)
end

def Rmk.parse_line(line, lid)
	case line
	when /^rule/
	when /^buildeach/
	when /^build/
	when /^default/
	when /^include/
	else
		match = /^(\s*)(\w+)\s+=\s*.*$/
		raise "#{lid} : Óï·¨´íÎó"
	end
end

def Rmk.parse_file(file)
	lines = IO.readlines file
	lid = 0
	regex = /(?<!\$)\$$/
	while lid < lines.size
		line, markid = '', lid
		while lines[lid].sub! regex, ''
			line += lines[lid]
			lid += 1
			break unless lid < lines.size
		end
		parse_line line + (lines[lid] || ''), markid
	end
end

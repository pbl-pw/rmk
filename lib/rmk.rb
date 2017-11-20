require 'rmk/version'

class Rmk
end

class Rmk::Dir

end

def Rmk.parse(srcroot, tgtroot = Dir.pwd)
end

def Rmk.parse_line(line, lid)
	case
	when line.sub! /^rule\s+/, ''
	when line.sub! /^buildeach\s+/, ''
	when line.sub! /^build\s+/, ''
	when line.sub! /^default\s+/, ''
	when line.sub! /^include\s+/, ''
	when line =~ /^\s*$/
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

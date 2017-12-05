require 'rmk/version'

class Rmk
	# normalize path, drive letter upcase and path seperator set to '/'
	# @param path [String]
	# @return [String]
	def self.normalize_path(path) path.gsub(?\\, ?/).sub(/^[a-z](?=:)/){|ch|ch.upcase} end

	# split parms using un-escape space as separator
	# @param line [String] str to split
	# @param sep [String] regex for separator
	# @return [Array<String>]
	def self.split_parms(line, sep = '\s+')
		result = []
		until line.empty?
			head, _, line = line.partition /(?<!\$)(?:\$\$)*\K#{sep}/
			result << head unless head.empty?
		end
		result
	end

	# create Rmk object
	# @param srcroot [String] source root dir,can be absolute or relative to output root(start with ..)
	# @param outroot [String] output root dir,can be absolute or relative to pwd,default pwd
	def initialize(srcroot:'', outroot:'')
		@srcroot = Rmk.normalize_path(::File.absolute_path srcroot, outroot)
		raise "source path '#{@srcroot}' not exist or not directory" unless ::Dir.exist?(@srcroot)
		@outroot = Rmk.normalize_path(::File.absolute_path outroot)
		warn 'in-source build' if @outroot == @srcroot
		@src_relative = srcroot.match?(/^\.\.[\\\/]/) && Rmk.normalize_path(srcroot)
		::Dir.mkdir @outroot unless ::Dir.exist? @outroot
		@srcfiles = {}
		@outfiles = {}
		@virtual_root = Rmk::VDir.new self, nil
		@virtual_root.parse
	end
	attr_reader :srcroot, :outroot, :src_relative, :virtual_root, :srcfiles, :outfiles

	# join src file path relative to out root, or absolute src path when not relative src
	def join_rto_src_path(path) ::File.join @src_relative ? @src_relative : @srcroot, path end

	# split path pattern to dir part and file match regex part
	# @param pattern [String] absolute path, can include '*' to match any char at last no dir part
	# @return [Array(String, <Regex, nil>)] when pattern include '*', return [dir part, file match regex]
	# ;otherwise return [origin pattern, nil]
	def split_path_pattern(pattern)
		match = /^([a-zA-Z]:\/(?:[^\/*]+\/)*)([^\/*]*)(?:\*([^\/*]*))?$/.match pattern
		raise "file syntax '#{pattern}' error" unless match
		dir, prefix, postfix = *match[1..3]
		regex = postfix && /#{Regexp.escape prefix}(.*)#{Regexp.escape postfix}$/
		[regex ? dir : pattern, regex]
	end

	# find files which can be build's imput file
	# @param pattern [String] absolute path to find src and out files which can include '*' to match any char at last no dir part
	# @return [Array(Array<Hash>, <Regex,nil>)] return [files, regex], or [files, nil] when not include '*' pattern
	def find_inputfiles(pattern)
		pattern = Rmk.normalize_path pattern
		path, regex = split_path_pattern pattern
		if regex
			files = []
			# mutex lock if multithread
			@outfiles.each {|k, v| files << v if k.start_with?(path) && k[path.size..-1].match?(regex)}
			::Dir[pattern].each do |fn|
				next if @outfiles.include? fn
				next files << @srcfiles[fn] if @srcfiles.include? fn
				files << (@srcfiles[fn] = VFile.new path:fn, is_src:true)
			end
			# mutex unlock if multithread
			return files, regex
		else
			# mutex lock if multithread
			return [@outfiles[path]], nil if @outfiles.include? path
			return [@srcfiles[path]], nil if @srcfiles.include? path
			raise "file '#{path}' not exist" unless ::File.exist? path
			file = @srcfiles[path] = VFile.new path:path, is_src:true
			# mutex unlock if multithread
			return [file], nil
		end
	end

	# find files which must be build's output
	# @param pattern [String] absolute path to find out files which can include '*' to match any char at last no dir part
	# @return [Array<Hash>] return Array of file, and Regex when has '*' pattern
	def find_outfiles(pattern)
		pattern = Rmk.normalize_path pattern
		path, regex = split_path_pattern pattern
		return @outfiles.include?(path) ? [@outfiles[path]] : [] unless regex
		files = []
		# mutex lock if multithread
		@outfiles.each {|k, v| files << v if k.start_with?(path) && k[path.size..-1].match?(regex)}
		# mutex unlock if multithread
		files
	end

	# register a out file
	# @param file [Rmk::VFile] virtual file object
	# @return [Rmk::VFile] return file obj back
	def add_out_file(file)
		raise "file '#{file.path}' has been defined" if @outfiles.include? file.path
		# mutex lock if multithread
		@srcfiles.delete file.path if @srcfiles.include? file.path
		@outfiles[file.path] = file
		# mutex unlock if multithread
	end

	# add default target
	def add_default(*files)
		# need implement
	end

	def build(*tgts)
	end

	class Vars; end
	class Rule < Vars
		def vars; self end
	end
	class VFile; end
end

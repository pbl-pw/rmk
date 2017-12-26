require_relative 'rmk'

# virtual file which represent a real OS file
class Rmk::VFile
	attr_reader :path, :vpath
	attr_accessor :is_src

	def self.generate_modified_id(path) File.mtime(path).to_i end

	def src?; @is_src end

	# builds which include this file as input file
	def input_ref_builds; @input_ref_builds end

	# builds which include this file as order-only file
	def order_ref_builds; @order_ref_builds end

	# build which include this file as output file
	attr_accessor :output_ref_build

	# create VFile
	# @param rmk [Rmk]
	# @param path [String] file's absolute path, must be normalized
	# @param vpath [String] file's virtual path
	def initialize(rmk:, path:, vpath:nil, is_src:false)
		@rmk, @path, @vpath, @is_src = rmk, path, vpath || nil, is_src
		@input_ref_builds, @order_ref_builds = [], []
		@output_ref_build = nil unless is_src
	end

	# generate file's modified id from current disk content
	def generate_modified_id; Rmk::VFile.generate_modified_id @path end

	# load last time modified id from system database
	# @return [Object] last stored modified id or nil for no last stored id
	def load_modified_id; @rmk.mid_storage[@path] end

	# store modified id to system database for next time check
	# @param mid [Object] modified id
	# @return [Object] stored modified id
	def store_modified_id(mid) @rmk.mid_storage[@path] = mid end

	# change to out file
	# @param outfile [Rmk::VFile] target file
	# @return [self]
	def change_to_out!(outfile)
		raise "outfile '#{@path}' can't change to outfile" if src?
		raise "outfile '#{@path}' can't change to srcfile" if outfile.src?
		unless @path == outfile.path && @vpath == outfile.vpath
			raise "srcfile '#{@path}' can't change to outfile '#{outfile.path}'"
		end
		@is_src = false
		@input_ref_builds.concat outfile.input_ref_builds
		@order_ref_builds.concat outfile.order_ref_builds
		@output_ref_build = outfile.output_ref_build
		self
	end

	def updated!(modified)
		input_ref_builds.each{|build| build.input_updated! modified}
		order_ref_builds.each{|build| build.order_updated! modified}
	end

	# check build's to run as srcfile, means file must be exist and can't check more than one time
	def check_for_build
		lmid, cmid = load_modified_id, generate_modified_id
		return updated! false if lmid == cmid
		store_modified_id cmid
		updated! true
	end
end

# Finded file struct
FFile = Struct.new :vfile, :vname, :stem

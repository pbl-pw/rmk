require_relative 'rmk'

# virtual file which represent a real OS file
class Rmk::VFile
	attr_reader :path, :vname, :vpath
	attr_accessor :is_src

	def src?; @is_src end

	# builds which include this file as input file
	def input_ref_builds; @input_ref_builds end

	# builds which include this file as order-only file
	def order_ref_builds; @order_ref_builds end

	# build which include this file as output file
	attr_accessor :output_ref_build

	def initialize(path:, vname:nil, vpath:nil, is_src:false)
		raise 'virtual file must set vpath' if vname && !vpath
		@path, @vname, @vpath, @is_src = path, vname, vpath, is_src
		@input_ref_builds, @order_ref_builds = [], []
		@output_ref_build = nil unless is_src
	end

	# change to out file
	# @param outfile [Rmk::VFile] target file
	# @return [self]
	def change_to_out!(outfile)
		raise "outfile '#{@path}' can't change to outfile" if src?
		raise "outfile '#{@path}' can't change to srcfile" if outfile.src?
		unless @path == outfile.path && (!@vpath || @vpath == outfile.vpath)
			raise "srcfile '#{@path}' can't change to outfile '#{outfile.path}'"
		end
		@vname = outfile.vname
		@is_src = false
		@input_ref_builds.concat outfile.input_ref_builds
		@order_ref_builds.concat outfile.order_ref_builds
		@output_ref_build = outfile.output_ref_build
		self
	end

	def updated!; input_ref_builds.each{|build| build.input_updated!} end

	def check_for_build
		updated!
	end
end

class Rmk; end

class Rmk::Vars
	# create vars
	# @param upstream [Rmk::Vars, nil] upstream vars for lookup var which current obj not include
	def initialize(upstream) @upstream, @vars = upstream, {} end

	def [](name) (@vars.include?(name) ? @vars[name] : @upstream&.[](name)).to_s end

	def []=(name, append = false, value)
		value = interpolate_str value
		@vars[name] = append ? self[name] + value : value
	end

	def include?(name) @vars.include?(name) || @upstream&.include?(name) end

	# only do #{\w+} interpolate
	def preprocess_str(str) str.gsub(/\$((?:\$\$)*){(\w+)}/){"#{$1}#{self[$2]}"} end

	# do all '$' prefix escape str interpolate
	def unescape_str(str) str.gsub(/\$(?:([\$\s>&])|(\w+))/){$1 || self[$2]} end

	# preprocess str, and then unescape the result
	def interpolate_str(str) unescape_str preprocess_str str end

	# merge other vars's define
	def merge!(oth) @vars.merge! oth.instance_variable_get(:@vars) end

	def freeze; @vars.freeze; super end

	class UpstreamWriter < self
		def initialize(upstream, vars) super upstream; @vars = vars end

		def []=(name, append = false, value)
			value = interpolate_str value
			@upstream[name] = append ? self[name] + value : value
		end

		# merge other vars's define
		def merge!(oth) end

		def freeze; end
	end

	def upstream_writer; UpstreamWriter.new @upstream, @vars end
end

class Rmk::MultiVarWriter
	def initialize
		@vars = []
	end

	# add vars
	# @param vars [Rmk::Vars] vars obj
	def <<(vars) @vars << vars end

	def []=(name, append = false, value)
		@vars.each{|var| var[name, append] = value}
	end
end

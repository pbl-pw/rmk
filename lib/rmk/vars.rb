class Rmk; end

class Rmk::Vars < Hash
	# create vars
	# @param upstream [Rmk::Vars, nil] upstream vars for lookup var which current obj not include
	def initialize(upstream) @upstream = upstream end
	attr_reader :upstream

	def [](name) (include?(name) ? super(name) : @upstream&.[](name)).to_s end

	def []=(name, append = false, value)
		value = interpolate_str value.to_s
		super name, append ? self[name] + value : value
	end

	def include?(name) super(name) || @upstream&.include?(name) end

	# only do #{\w+} interpolate
	def preprocess_str(str) str.gsub(/\$((?:\$\$)*){(\w+)}/){"#{$1}#{self[$2]}"} end

	# do all '$' prefix escape str interpolate
	def unescape_str(str) str.gsub(/\$(?:([\$\s>&])|(\w+))/){$1 || self[$2]} end

	# preprocess str, and then unescape the result
	def interpolate_str(str) unescape_str preprocess_str str end

	class UpstreamWriter
		def initialize(upstream, vars) @upstream, @vars = upstream, vars end

		def [](name) (@vars.include?(name) ? @vars[name] : @upstream&.[](name)).to_s end

		def []=(name, append = false, value)
			value = @vars.interpolate_str value
			@upstream.store name, append ? self[name] + value : value
		end
	end

	def upstream_writer; UpstreamWriter.new @upstream, self end
end

class Rmk::MultiVarWriter
	# create
	# @param vars [Array<Rmk::Vars>] init Vars obj array
	def initialize(*vars) @vars = vars end

	# add vars obj to array
	# @param vars [Rmk::Vars] vars obj
	def <<(vars) @vars << vars end

	# write var to all vars obj
	# @param name [String]
	# @param append [Boolean] is '+=' mode ?
	# @param value [String, nil]
	def []=(name, append = false, value) @vars.each{|var| var[name, append] = value} end
end

require_relative 'rmk'

class Rmk::Vars
	# create vars
	# @param upstream [Rmk::Vars, nil] upstream vars for lookup var which current obj not include
	def initialize(upstream, **presets) @upstream, @vars = upstream, presets end

	def [](name) (@vars.include?(name) ? @vars[name] : @upstream&.[](name)).to_s end

	def []=(name, value) @vars[name] = value end

	def include?(name) @vars.include?(name) || @upstream&.include?(name) end

	# only do #{\w+} interpolate
	def preprocess_str(str) str.gsub(/\$((?:\$\$)*){(\w+)}/){"#{$1}#{self[$2]}"} end

	# do all '$' prefix escape str interpolate
	def unescape_str(str) str.gsub(/\$(?:([\$\s>&])|(\w+))/){$1 || self[$2]} end

	# preprocess str, and then unescape the result
	def interpolate_str(str) unescape_str preprocess_str str end
end

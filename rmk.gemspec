# coding: utf-8
lib = File.join __dir__, 'lib'
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'rmk/version'

Gem::Specification.new do |spec|
	spec.name = 'rmk'
	spec.version = Rmk::VERSION
	spec.authors = ['pbl']
	spec.email = ['a@pbl.pw']

	spec.summary = %q{build tool like make, tup, ninja}
	spec.description = %q{build tool like make, tup, ninja}
	spec.homepage = 'https://github.com/pbl-pw/rmk'

	# Prevent pushing this gem to RubyGems.org. To allow pushes either set the 'allowed_push_host'
	# to allow pushing to a single host or delete this section to allow pushing to any host.
	if spec.respond_to?(:metadata)
		spec.metadata['allowed_push_host'] = 'https://github.com/pbl-pw/rmk'
	else
		raise 'RubyGems 2.0 or newer is required to protect against public gem pushes.'
	end

	spec.files = `git ls-files -z`.split("\x0").reject do |f|
		f.match(%r{^(test|spec|features)/})
	end
	spec.bindir = 'exe'
	spec.executables = spec.files.grep(%r{^exe/}) {|f| File.basename(f)}
	spec.require_paths = ['lib']

	spec.add_development_dependency 'bundler', '~> 1.15'
	spec.add_development_dependency 'rake', '~> 10.0'
	spec.add_development_dependency 'minitest', '~> 5.0'
	spec.add_development_dependency 'rubocop'

	spec.add_dependency 'iniparse'
end

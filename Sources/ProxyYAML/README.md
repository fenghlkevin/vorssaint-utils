# YAML parsing bridge

Vendored libyaml 0.2.5, unmodified upstream `src/*.c`, `yaml_private.h` and
`include/yaml.h`; local config.h supplies release version macros.
Source: https://github.com/yaml/libyaml/tree/0.2.5
License: Resources/libyaml-LICENSE.txt (MIT).

ProxyYAML.m converts a bounded, single YAML document into JSON. The supported
profile subset rejects aliases, merge keys, duplicate keys and custom tags.
Credentials and original YAML are never included in parser errors.

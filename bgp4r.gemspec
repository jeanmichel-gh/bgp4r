# -*- encoding: utf-8 -*-

Gem::Specification.new do |s|
  s.name = %q{bgp4r}
  s.version = "0.0.3"

  s.required_rubygems_version = Gem::Requirement.new(">= 0") if s.respond_to? :required_rubygems_version=
  s.authors = ["Jean-Michel Esnault"]
  s.date = %q{2009-06-29}
  s.description = %q{BGP4R is a BGP-4 ruby library to create,  send, and receive  BGP messages in an  object oriented manner}
  s.email = %q{jesnault@gmail.com}
  s.extra_rdoc_files = [
    "LICENSE.txt",
     "README.rdoc"
  ]
  s.files = [
    "COPYING",
     "LICENSE.txt",
     "README.rdoc",
     "bgp/aggregator.rb",
     "bgp/as_path.rb",
     "bgp/atomic_aggregate.rb",
     "bgp/attribute.rb",
     "bgp/attributes.rb",
     "bgp/cluster_list.rb",
     "bgp/common.rb",
     "bgp/communities.rb",
     "bgp/extended_communities.rb",
     "bgp/extended_community.rb",
     "bgp/iana.rb",
     "bgp/io.rb",
     "bgp/label.rb",
     "bgp/local_pref.rb",
     "bgp/message.rb",
     "bgp/mp_reach.rb",
     "bgp/multi_exit_disc.rb",
     "bgp/neighbor.rb",
     "bgp/next_hop.rb",
     "bgp/nlri.rb",
     "bgp/orf.rb",
     "bgp/origin.rb",
     "bgp/originator_id.rb",
     "bgp/path_attribute.rb",
     "bgp/prefix_orf.rb",
     "bgp/rd.rb",
     "examples/bgp",
     "examples/routegen",
     "examples/routegen.yml",
     "test/aggregator_test.rb",
     "test/as_path_test.rb",
     "test/atomic_aggregate_test.rb",
     "test/attribute_test.rb",
     "test/cluster_list_test.rb",
     "test/common_test.rb",
     "test/communities_test.rb",
     "test/extended_communities_test.rb",
     "test/extended_community_test.rb",
     "test/label_test.rb",
     "test/local_pref_test.rb",
     "test/message_test.rb",
     "test/mp_reach_test.rb",
     "test/multi_exit_disc_test.rb",
     "test/neighbor_test.rb",
     "test/next_hop_test.rb",
     "test/nlri_test.rb",
     "test/origin_test.rb",
     "test/originator_id_test.rb",
     "test/path_attribute_test.rb",
     "test/prefix_orf_test.rb",
     "test/rd_test.rb"
  ]
  s.homepage = %q{http://github.com/jesnault/bgp4r/tree/master}
  s.rdoc_options = ["--quiet", "--title", "A BGP-4 Ruby Library", "--line-numbers"]
  s.require_paths = ["."]
  s.required_ruby_version = Gem::Requirement.new(">= 1.8.6")
  s.rubyforge_project = %q{bgp4r}
  s.rubygems_version = %q{1.3.4}
  s.summary = %q{A BGP-4 Ruby Library}
  s.test_files = [
    "test/aggregator_test.rb",
     "test/as_path_test.rb",
     "test/atomic_aggregate_test.rb",
     "test/attribute_test.rb",
     "test/cluster_list_test.rb",
     "test/common_test.rb",
     "test/communities_test.rb",
     "test/extended_communities_test.rb",
     "test/extended_community_test.rb",
     "test/label_test.rb",
     "test/local_pref_test.rb",
     "test/message_test.rb",
     "test/mp_reach_test.rb",
     "test/multi_exit_disc_test.rb",
     "test/neighbor_test.rb",
     "test/next_hop_test.rb",
     "test/nlri_test.rb",
     "test/origin_test.rb",
     "test/originator_id_test.rb",
     "test/path_attribute_test.rb",
     "test/prefix_orf_test.rb",
     "test/rd_test.rb"
  ]

  if s.respond_to? :specification_version then
    current_version = Gem::Specification::CURRENT_SPECIFICATION_VERSION
    s.specification_version = 3

    if Gem::Version.new(Gem::RubyGemsVersion) >= Gem::Version.new('1.2.0') then
    else
    end
  else
  end
end

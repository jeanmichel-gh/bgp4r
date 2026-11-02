#--
# Copyright 2026 Jean-Michel Esnault.
# All rights reserved.
# See LICENSE.txt for permissions.
#
#
# This file is part of BGP4R.
#
# BGP4R is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# BGP4R is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with BGP4R.  If not, see <http://www.gnu.org/licenses/>.
#++

# `bgp/daemon/config.rb`: the configuration as set lines.
#
#   ruby -I. test/unit/daemon/config_test.rb
#
# **The expectations here are this reader's arithmetic and not anybody's
# document**, which is worth saying because every other vector in this
# suite is hex out of an RFC. There is no document behind set lines: the
# shape is `Drivers::Ospfd`'s requirement that `config.compare` answer
# lines and `config.replace` take them, read in routescope at `7eabde1`,
# and the grammar is this file's own. So what is asserted is a property
# rather than a quotation: a configuration renders to lines that read
# back as the same configuration, and a `compare` loaded back on top of
# the configuration it was taken from gives the one it was taken to.

require 'test/unit'
require 'bgp/daemon/config'

class BGP_Daemon_Config_Test < Test::Unit::TestCase

  C = BGP::Daemon::Config

  # Every shape the node file has: scalars, a keyed list, an ordinal
  # list, an argument list, a nested mapping, a mapping with a numeric
  # key, a plain list and the two empties.
  def config
    { 'router_id' => '10.255.0.1', 'as' => 65_000, 'rib' => true, 'log_level' => 'info',
      'neighbors' => [{ 'address' => '10.0.10.1', 'as' => 65_010, 'connect' => true,
                        'hold_time' => 30, 'description' => 'inj1',
                        'capabilities' => ['as4_byte', { 'role' => 'customer' },
                                           { 'add_path' => [3, 1, 1] }] },
                      { 'address' => '10.0.11.1', 'as' => 65_000 }],
      'originate' => [{ 'prefixes' => ['10.255.0.0/24', '10.255.1.0/24'], 'med' => 10,
                        'communities' => ['65000:1'] }],
      'export' => { 'next_hops' => { 1 => '10.0.20.1' }, 'route_reflector' => false,
                    'clients' => [], 'mrai' => { 'ebgp' => 0, 'ibgp' => 0 } },
      'fib' => { 'table' => 100 } }
  end

  def test_a_configuration_renders_one_line_per_leaf
    lines = C.to_set(config)
    assert_include(lines, 'set router_id 10.255.0.1')
    assert_include(lines, 'set neighbors 10.0.10.1 hold_time 30')
    assert_include(lines, 'set originate 0 prefixes 10.255.0.0/24')
    assert_include(lines, 'set export next_hops 1 10.0.20.1')
    assert_include(lines, 'set export mrai ebgp 0')
    assert_include(lines, 'set fib table 100')
  end

  # The property the whole file rests on. It is asserted on the **lines**
  # and not on the trees: a YAML Integer key and the token it renders as
  # are the same line, so comparing trees would fail for a difference
  # that cannot reach any reader.
  def test_a_configuration_reads_back_as_itself
    lines = C.to_set(config)
    assert_equal(lines, C.to_set(C.from_set(lines)))
  end

  def test_nothing_changed_compares_as_nothing
    assert_equal([], C.compare(config, C.from_set(C.to_set(config))))
    assert_equal([], C.changed_paths(config, config))
  end

  def test_a_keyed_list_keeps_the_key_it_was_keyed_by
    back = C.from_set(C.to_set(config))
    assert_equal(['10.0.10.1', '10.0.11.1'], back['neighbors'].map { |n| n['address'] })
    assert_equal(65_010, back['neighbors'].first['as'])
  end

  # A name on its own, a name and one argument, a name and three. All
  # three are what `Peer#add_capability` reads.
  def test_an_argument_list_keeps_its_arguments
    lines = C.to_set(config)
    assert_include(lines, 'set neighbors 10.0.10.1 capabilities as4_byte')
    assert_include(lines, 'set neighbors 10.0.10.1 capabilities role customer')
    assert_include(lines, 'set neighbors 10.0.10.1 capabilities add_path 3 1 1')
    assert_equal(['as4_byte', { 'role' => 'customer' }, { 'add_path' => [3, 1, 1] }],
                 C.from_set(lines)['neighbors'].first['capabilities'])
  end

  # The one that caught a real bug: `seen` was keyed by the whole path a
  # line named rather than by the path to the list, so each capability
  # line cleared the list and a neighbor kept only its last capability.
  def test_three_capability_lines_are_three_capabilities
    tree = C.from_set(['set neighbors 10.0.10.1 capabilities as4_byte',
                       'set neighbors 10.0.10.1 capabilities route_refresh',
                       'set neighbors 10.0.10.1 capabilities add_path 3 1 1'])
    assert_equal(3, tree['neighbors'].first['capabilities'].size)
  end

  # **`clients: []` and no `clients` key are opposite**, measured in
  # `bgp/rib/export.rb`: with none, `Export#clients?` answers true for
  # every internal peer, and with an empty list it answers false for all
  # of them. So an empty list has to survive, which is what `[]` is for.
  def test_an_empty_list_is_not_the_same_as_no_key
    assert_include(C.to_set(config), 'set export clients []')
    assert_equal([], C.from_set(C.to_set(config))['export']['clients'])
    gone = config
    gone['export'].delete('clients')
    assert_equal(nil, C.from_set(C.to_set(gone))['export']['clients'])
    assert_equal(['delete export clients'], C.compare(config, gone))
  end

  # `export: {}` is a transit router with no policy, which `Speaker#rib?`
  # reads as router mode on. A rendering that dropped it would turn that
  # off.
  def test_an_empty_mapping_survives
    lines = C.to_set('as' => 65_000, 'export' => {})
    assert_include(lines, 'set export {}')
    assert_equal({}, C.from_set(lines)['export'])
  end

  def test_a_nil_value_is_the_same_as_no_key
    assert_equal(C.to_set('as' => 65_000), C.to_set('as' => 65_000, 'description' => nil))
  end

  def test_a_value_with_a_space_is_quoted_and_comes_back_whole
    lines = C.to_set('neighbors' => [{ 'address' => '10.0.10.1', 'description' => 'the injector' }])
    assert_include(lines, 'set neighbors 10.0.10.1 description "the injector"')
    assert_equal('the injector', C.from_set(lines)['neighbors'].first['description'])
  end

  def test_a_comment_and_a_blank_line_are_ignored
    assert_equal({ 'as' => 65_000 }, C.from_set(['# a comment', '', '  ', 'set as 65000']))
  end

  def test_a_type_comes_from_the_token
    tree = C.from_set(['set a 65000', 'set b true', 'set c false', 'set d 1.5', 'set e x'])
    assert_equal([65_000, true, false, 1.5, 'x'], %w[a b c d e].map { |k| tree[k] })
  end

  # ---- compare ----

  def test_one_changed_scalar_is_one_set_line
    edited = C.apply(config, ['set neighbors 10.0.10.1 hold_time 60'])
    assert_equal(['set neighbors 10.0.10.1 hold_time 60'], C.compare(config, edited))
    assert_equal([%w[neighbors 10.0.10.1 hold_time]], C.changed_paths(config, edited))
  end

  # **A subtree that is gone is named once, at its root.** Deleting its
  # leaves instead leaves the mapping behind, and for `export` that is
  # `export => {}`, which `Speaker#rib?` reads as router mode **on**
  # where the absent key means off. So the test is the behaviour and not
  # the wording.
  def test_a_whole_key_gone_is_one_delete_of_the_key
    gone = C.apply(config, ['delete export'])
    assert_equal(['delete export'], C.compare(config, gone))
    assert_equal(nil, C.apply(config, C.compare(config, gone))['export'])
  end

  def test_a_neighbor_gone_is_one_delete_of_the_neighbor
    gone = C.apply(config, ['delete neighbors 10.0.11.1'])
    assert_equal(['delete neighbors 10.0.11.1'], C.compare(config, gone))
    assert_equal(['10.0.10.1'],
                 C.apply(config, C.compare(config, gone))['neighbors'].map { |n| n['address'] })
  end

  # The property that makes `compare` worth answering at all: its lines
  # are `config.load`'s input, so loading them on the configuration they
  # were taken from has to give the one they were taken to. Every edit
  # shape, because the list cases are where it nearly went wrong.
  #
  # **Sorted, because the order of the lines is a Hash's insertion order
  # and carries no meaning here.** A key deleted and set again comes back
  # at the end of its mapping rather than where it was, so a replay of a
  # list edit renders the same lines in another order. Nothing reads
  # that: `compare` and `changed_paths` both group by leaf path, and a
  # driver's pane shows `compare`'s own list beside the text. Asserting
  # the order would be asserting the Hash.
  def test_a_compare_loaded_back_gives_the_candidate_it_came_from
    [['a scalar',            ['set neighbors 10.0.10.1 as 65099']],
     ['a neighbor gone',     ['delete neighbors 10.0.11.1']],
     ['every neighbor gone', ['delete neighbors']],
     ['a key gone',          ['delete export']],
     ['a nested key gone',   ['delete export mrai']],
     ['a leaf gone',         ['delete neighbors 10.0.10.1 description']],
     ['a list replaced',     ['set originate 0 prefixes 10.255.9.0/24']],
     ['a list shortened',    ['delete originate 0 prefixes',
                              'set originate 0 prefixes 10.255.9.0/24']],
     ['a list lengthened',   ['set originate 0 prefixes 10.255.0.0/24',
                              'set originate 0 prefixes 10.255.1.0/24',
                              'set originate 0 prefixes 10.255.2.0/24']],
     ['a capability gone',   ['delete neighbors 10.0.10.1 capabilities role']],
     ['an empty list filled', ['set export clients 1.1.1.1']],
     ['a neighbor added',    ['set neighbors 10.0.12.1 as 65012']],
     ['a next hop gone',     ['delete export next_hops 1']]].each do |name, edit|
      candidate = C.apply(config, edit)
      diff = C.compare(config, candidate)
      # **The edit has to have done something, or the case proves
      # nothing.** Two of these passed vacuously while they were
      # written: `delete neighbors ... capabilities add_path` and
      # `delete export next_hops 1` were both silently no-ops, so the
      # candidate equalled the configuration, `compare` answered an empty
      # list, and replaying an empty list of course reproduced it. The
      # bugs were real and are fixed in `unset`; this assertion is what
      # makes the case able to see them.
      assert_not_equal([], diff, "#{name}: the edit changed nothing, so the case proves nothing")
      replayed = C.apply(config, diff)
      assert_equal(C.to_set(candidate).sort, C.to_set(replayed).sort, name)
    end
  end

  # The two shapes `unset` was wrong about, asserted on the value rather
  # than through a round trip, since a round trip is what hid them.
  def test_a_delete_takes_away_what_it_names
    gone = C.apply(config, ['delete neighbors 10.0.10.1 capabilities add_path'])
    assert_equal(['as4_byte', { 'role' => 'customer' }],
                 gone['neighbors'].first['capabilities'])
    # A YAML key need not be a String: next_hops is keyed by the AFI.
    assert_equal({}, C.apply(config, ['delete export next_hops 1'])['export']['next_hops'])
    # A bare capability too, which was the half that did work.
    assert_equal([{ 'role' => 'customer' }, { 'add_path' => [3, 1, 1] }],
                 C.apply(config, ['delete neighbors 10.0.10.1 capabilities as4_byte'])['neighbors']
                   .first['capabilities'])
  end

  def test_a_delete_of_something_absent_changes_nothing
    ['delete export nonsense', 'delete nope deep key', 'delete neighbors 9.9.9.9',
     'delete originate 7', 'delete neighbors 10.0.10.1 capabilities nonsense'].each do |line|
      assert_equal(C.to_set(config), C.to_set(C.apply(config, [line])), line)
    end
  end

  # The rule that makes one grammar serve a plain list and a scalar being
  # changed: within one call the first `set` to a path replaces and the
  # rest collect. Without it `config.load` of one scalar would turn the
  # value it was changing into a two element list.
  def test_the_first_set_to_a_path_replaces_and_the_rest_collect
    once = C.apply(config, ['set neighbors 10.0.10.1 hold_time 60'])
    assert_equal(60, once['neighbors'].first['hold_time'])
    twice = C.apply(config, ['set export clients 1.1.1.1', 'set export clients 2.2.2.2'])
    assert_equal(['1.1.1.1', '2.2.2.2'], twice['export']['clients'])
    # A later call starts again rather than going on collecting.
    again = C.apply(twice, ['set export clients 3.3.3.3'])
    assert_equal('3.3.3.3', again['export']['clients'])
  end

  # ---- refusals ----

  # It refuses what it cannot render or read, and nothing else, which is
  # the library's one rule about refusing.
  def test_a_shape_it_cannot_render_is_refused
    assert_raise(C::Error) { C.to_set('a list') }
    assert_raise(C::Error) { C.to_set('neighbors' => [{ 'as' => 1 }]) }   # no address
    assert_raise(C::Error) { C.to_set('neighbors' => ['10.0.0.1']) }      # not a mapping
    assert_raise(C::Error) { C.to_set('communities' => [{ 'a' => 1 }]) }  # a plain list of mappings
    assert_raise(C::Error) do
      C.to_set('neighbors' => [{ 'address' => '1.1.1.1', 'capabilities' => [{ 'a' => 1, 'b' => 2 }] }])
    end
  end

  def test_a_line_it_cannot_read_is_refused_and_names_its_number
    assert_raise(C::Error) { C.from_set(['set as']) }
    assert_raise(C::Error) { C.from_set(['delete']) }
    assert_raise(C::Error) { C.from_set(['nonsense as 1']) }
    assert_raise(C::Error) { C.from_set(['set originate x med 1']) }
    assert_raise(C::Error) { C.from_set(['set as 1 "unclosed']) }
    e = assert_raise(C::Error) { C.from_set(['set as 65000', 'set as']) }
    assert_match(/line 2/, e.message)
  end

  # A text it cannot read must leave what it was given alone, which is
  # what lets `config.replace` answer errors and keep the candidate.
  def test_a_text_it_cannot_read_changes_nothing
    original = config
    copy = C.deep_copy(original)
    assert_raise(C::Error) { C.apply(original, ['set as 65001', 'nonsense']) }
    assert_equal(C.to_set(copy), C.to_set(original))
  end

  def test_a_deep_copy_shares_nothing
    copy = C.deep_copy(config)
    copy['neighbors'].first['as'] = 1
    copy['export']['mrai']['ebgp'] = 9
    assert_equal(65_010, config['neighbors'].first['as'])
    assert_equal(0, config['export']['mrai']['ebgp'])
  end

  def test_the_yaml_form_is_the_file_a_person_edits
    require 'yaml'
    text = C.to_yaml_text(config)
    assert_equal(C.to_set(config), C.to_set(YAML.safe_load(text)))
  end

end

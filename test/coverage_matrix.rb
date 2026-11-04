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

require 'bgp4r'
require 'bgp/fault'
require 'bgp/gen'

# What is exercised and what is not, per path attribute and per address
# family, printed from the library:
#
#   ruby test/coverage_matrix.rb
#   rake coverage:matrix
#
# **It exists because the answer was already computable and nobody had
# computed it.** Measured the first time on 2026-11-03: 24 path
# attributes are registered, 11 have a case in `BGP::Fault::CATALOG` and
# 13 have none, so thirteen of them have never been put in front of a
# router at all. That is the kind of hole the inverted ADD-PATH
# Send/Receive field sat in for years, and nothing in the tree said it
# was there.
#
# **Almost everything here is derived, and the one declared part is
# marked.** The attribute list is `Attr.registrations`, the fault
# coverage is `Fault.catalog` grouped by the attribute each case builds,
# the family list is **probed** from the build gate in `mp_reach.rb`,
# the family names are `IANA.safi_name`, and the lab tests are a glob.
# So a family wired in, an attribute registered, or a fault case added
# shows up here the day it lands with no edit to this file.
#
# `VOUCHES` is the exception and has to be: what a lab test's existence
# *proves* is a judgement, and the same two files can mean opposite
# things. `evpn_gobgp_test.rb` says a router read our octets;
# `mcast_vpn_gobgp_test.rb` says the router does not have the family at
# all, so it vouches for nothing about our encoding. A column that
# printed "yes" for both would be the confident wrong answer CLAUDE.md
# calls the worst failure a conformance tool has. So each verdict is
# written down with the document section that justifies it, and
# `test/unit/coverage_matrix_test.rb` requires every lab file on disk to
# be accounted for and every citation to resolve.
#
# This prints; it does not assert. The counts in its output are not
# written down in any document, for the reason `rake to_hash:status`
# exists.
module CoverageMatrix

  # The AFIs worth probing.
  #
  # **Measured on 2026-11-03, because the comment here first guessed and
  # a sabotage caught it.** It said these were the four that carry a
  # family of their own, 25 for EVPN and 16388 for BGP-LS, which reads
  # as though EVPN appeared only under AFI 25. It does not. The gate's
  # `set` branches on the **SAFI** for every family but unicast and
  # multicast, so AFI 1 with SAFI 70 is accepted, and **AFI 1 alone
  # yields every SAFI in the table**. Narrowing this list to [1] changed
  # no row, which is how the guess surfaced.
  #
  # The list stays at four because the question it asks is which
  # [afi, safi] pairs the gate accepts, and there the AFI does matter:
  # AFI 25 and 16388 refuse SAFI 1 and 2, since that arm has to build a
  # prefix. `test_the_gate_keys_on_the_safi_for_every_family_but_two`
  # pins both halves, so a gate that grows an AFI check fails there
  # rather than quietly dropping a row.
  PROBE_AFIS = [1, 2, 25, 16388].freeze

  # What a router's lab tests actually vouch for about one family.
  #
  # **Declared, not derived.** The verdicts:
  #
  #   :both     the router encodes the family too, so its output feeds
  #             our decoder as well as its parser reading what we send
  #   :send     the router reads what we send and we read its verdict;
  #             our decode side is not exercised by it
  #   :absence  the router does not have the family. The test measures
  #             how it says so, and vouches for **nothing** about our
  #             octets
  #   :none     no lab test for that router
  #
  # `:doc` is where the measurement is written up. The guard requires it
  # to exist, so a verdict cannot cite a document that is not there.
  #
  # `:via` names the lab test stems that carry a family which has no
  # test of its own. Unicast is the case: no file is named for it, and
  # the fault matrix, the export tests and the add-path tests all put
  # plain IPv4 unicast in front of a real router. **Without it unicast
  # printed a verdict beside a count of zero**, which is two columns
  # disagreeing, and that is how this key was found.
  VOUCHES = {
    'unicast'      => { :gobgp => :send,    :frr => :send,
                        :via => %w[fault_matrix rib_router add_path],
                        :doc => 'docs/protocol-testing.md' },
    'multicast'    => { :gobgp => :none,    :frr => :none },
    'labelled'     => { :gobgp => :none,    :frr => :none },
    'mcast-vpn'    => { :gobgp => :absence, :frr => :absence,
                        :doc => 'docs/mcast-vpn.md' },
    'evpn'         => { :gobgp => :send,    :frr => :send,
                        :doc => 'docs/evpn.md' },
    'bgp-ls'       => { :gobgp => :both,    :frr => :absence,
                        :doc => 'docs/bgp-ls.md' },
    # GoBGP's own SAFI 72 verdict is in `link_state_gobgp_test.rb`, which
    # offers the family, reads it back as UnknownFamily and asserts the
    # daemon's `unknown route family` line. **This said `:none` first**,
    # and the count beside it said one test, which is what sent a reader
    # to the file. One SAFI of a pair measured and the other an absence
    # is the VPN flow spec shape again.
    'bgp-ls-vpn'   => { :gobgp => :absence, :frr => :absence,
                        :doc => 'docs/bgp-ls.md' },
    'vpn'          => { :gobgp => :none,    :frr => :none },
    'vpn-multicast' => { :gobgp => :none,   :frr => :none },
    'rt-constrain' => { :gobgp => :send,    :frr => :none,
                        :doc => 'docs/flow-spec.md' },
    'flow-spec'    => { :gobgp => :send,    :frr => :send,
                        :doc => 'docs/flow-spec.md' },
    'flow-spec-vpn' => { :gobgp => :send,   :frr => :absence,
                        :doc => 'docs/flow-spec.md' },
  }.freeze

  VERDICTS = %i[both send absence none].freeze

  # The family a lab test file belongs to, by its own stem. Declared for
  # the same reason `VOUCHES` is: `link_state_gobgp_test` covers SAFI 71
  # and 72 and the two have different verdicts, so no rule over the
  # filename can place it.
  LAB_FAMILIES = {
    'flow_spec'    => %w[flow-spec flow-spec-vpn],
    'evpn'         => %w[evpn],
    'rt_constrain' => %w[rt-constrain],
    'mcast_vpn'    => %w[mcast-vpn],
    'link_state'   => %w[bgp-ls bgp-ls-vpn],
  }.freeze

  # Lab tests against a router that are **not** about one address
  # family, so they place no row in the family table. Declared so the
  # guard can insist every `*_gobgp_test` and `*_frr_test` on disk is
  # either a family's or named here, which is what stops a new one being
  # silently absent from this report.
  NOT_A_FAMILY = {
    'fault_matrix' => 'the RFC 7606 matrix, which is per attribute',
    'rib_router'   => 'our export side, which is per route and not per family',
    'add_path'     => 'RFC 7911, which cuts across families',
    'attr_set'     => 'attribute 128, which has no NLRI',
    'capabilities' => 'OPEN capabilities, which are per session and not per family',
    'gen'          => 'bgp/gen, a generator; docs/route-generation.md phase 6 reports those',
  }.freeze

  # An attribute a lab test names outright, with no fault case behind
  # it. One entry so far: ATTR_SET, whose `attr_set_gobgp_test.rb` runs
  # a gobgpd in the middle. **This is a constant of the module and not
  # of its singleton class**, which is where it was written first, so
  # `CoverageMatrix::DIRECT` raised NameError in the guard while every
  # method inside resolved it.
  DIRECT = { 'Attr_set' => %w[gobgp] }.freeze

  LAB = 'test/functional/lab'

  # The lab tests that send a bgp/gen feed to a router, one per router:
  # gen_gobgp_test.rb and gen_frr_test.rb. Each declares the families it
  # generates in a GEN_FAMILIES line, read here as text, since loading a
  # test file would run it. test/unit/coverage_matrix_test.rb holds that
  # line to the file's own 'family' literals, both ways.
  GEN_LAB = "#{LAB}/gen_%s_test.rb"

  class << self

    # ---- derived: the attributes ------------------------------------

    def attributes
      BGP::Attr.registrations.sort_by { |r| r.type }
    end

    # The catalog's cases, keyed by the attribute type each one builds.
    # A case whose block answers a whole `Path_attribute` is keyed by its
    # first attribute, which is what `duplicate_attr` and
    # `tunnel_encap_sub_tlv` need. A case that cannot be placed lands
    # under nil, and the guard fails on that rather than letting a row
    # read as uncovered.
    def faults_by_type
      out = {}
      BGP::Fault.catalog.each do |e|
        (out[fault_type(e)] ||= []) << e[:name]
      end
      out
    end

    def fault_type(entry)
      a = entry[:build].call
      return a.type if a.respond_to?(:type)
      a.attributes.first.type
    rescue StandardError
      nil
    end

    # ---- derived: the families --------------------------------------

    # Every [afi, safi] the build gate accepts, probed rather than
    # listed: `MpReachCommon#set` raises for a SAFI with no arm, so
    # building an empty attribute per pair is the question asked
    # directly. A family wired in appears here with no edit.
    def families
      PROBE_AFIS.flat_map { |afi|
        (0..255).select { |safi| gate_knows?(afi, safi) }
                .collect { |safi| [afi, safi] }
      }
    end

    def gate_knows?(afi, safi)
      BGP::Mp_reach.new(:afi => afi, :safi => safi,
                        :nexthop => ['10.0.0.1'], :nlris => [])
      true
    rescue StandardError
      false
    end

    # The slug a family is known by here. Derived from the SAFI, since
    # IANA's own name is what the library already prints.
    SLUGS = {
      1 => 'unicast', 2 => 'multicast', 4 => 'labelled', 5 => 'mcast-vpn',
      70 => 'evpn', 71 => 'bgp-ls', 72 => 'bgp-ls-vpn',
      # 128 and 129 shared the slug 'vpn' until 2026-11-03, which made
      # this report say eleven families where the gate accepts twelve
      # SAFIs: IANA names them Labeled VPN Unicast and Labeled VPN
      # Multicast, so one row printed under the other's name. That is
      # `unnamed_safis` one step subtler, a family the gate knows that
      # the report cannot show, and it was found by building a specimen
      # per family in bgp/specimen.rb rather than by reading this table.
      128 => 'vpn', 129 => 'vpn-multicast', 132 => 'rt-constrain',
      133 => 'flow-spec', 134 => 'flow-spec-vpn',
    }.freeze

    def slug(safi) ; SLUGS[safi] ; end

    # The distinct families the gate knows, as slugs, in SAFI order.
    def family_slugs
      families.collect { |_, safi| slug(safi) }.compact.uniq
    end

    # A SAFI the gate accepts and this file cannot name. The guard fails
    # on it, so a family wired in without a slug is caught here rather
    # than printing as a blank row.
    def unnamed_safis
      families.collect { |_, safi| safi }.uniq.reject { |s| SLUGS.key?(s) }
    end

    # ---- derived: the lab tests -------------------------------------

    # Every lab test that drives a real router, by stem and router.
    def router_tests
      Dir["#{LAB}/*_test.rb"].sort.filter_map { |f|
        b = File.basename(f, '_test.rb')
        m = b.match(/\A(.+)_(gobgp|frr)\z/) or next
        [m[1], m[2].to_sym, f]
      }
    end

    # The lab files that carry one family against one router: the ones
    # named for it, plus any the entry's `:via` names. Both halves,
    # because a verdict printed beside a count of zero is two columns
    # disagreeing and a reader cannot tell which is wrong.
    def router_tests_for(slug, router)
      via = Array((VOUCHES[slug] || {})[:via])
      router_tests.select { |stem, r, _|
        r == router &&
          (Array(LAB_FAMILIES[stem]).include?(slug) || via.include?(stem))
      }.collect { |_, _, f| File.basename(f) }
    end

    # A router test whose stem is neither a family's nor declared as not
    # being one. The guard fails on it.
    #
    # **Split in two so the rejection itself is testable.** Its only
    # consumer is its own guard, so stubbing it to answer [] passed the
    # whole suite: nothing else in the report reads it, which is the
    # #246 row-parser case again. `unplaced` takes the stems, so a test
    # can hand it a made up one and watch it come back.
    def unplaced_router_tests
      unplaced(router_tests.collect { |stem, _, _| stem }.uniq)
    end

    def unplaced(stems)
      stems.reject { |s| LAB_FAMILIES.key?(s) || NOT_A_FAMILY.key?(s) }
    end

    def vouches(slug) ; VOUCHES[slug] ; end

    # ---- derived: the generators ------------------------------------

    # The slug of a bgp/gen family name, through BGP::Specimen, which is
    # where the names come from.
    def gen_slug(name)
      f = BGP::Specimen.families.find { |n, _, _| n.to_s == name } or return nil
      slug(f[2])
    end

    # The families BGP::Gen has a generator for, as slugs.
    def generator_slugs
      BGP::Gen::GENERATORS.keys.collect { |n| gen_slug(n) }
    end

    # The GEN_FAMILIES a gen lab file declares, or [] for no such line.
    def declared_gen_families(text)
      m = text.match(/^\s*GEN_FAMILIES\s*=\s*%w\[([^\]]*)\]/m) or return []
      m[1].split
    end

    # Every 'family' => name literal in a gen lab file.
    def gen_literals(text)
      text.scan(/'family'\s*=>\s*'([a-z_]+)'/).flatten.uniq
    end

    # The routers a generated feed of one family has been sent to.
    def gen_routers(slug)
      %i[gobgp frr].select { |r|
        f = format(GEN_LAB, r)
        File.exist?(f) && declared_gen_families(File.read(f)).any? { |n| gen_slug(n) == slug }
      }
    end

    # ---- the report -------------------------------------------------

    def report
      attribute_table + "\n" + family_table + "\n" + summary
    end

    def attribute_table
      f = faults_by_type
      out = +"Path attributes\n\n"
      out << format("%-4s %-28s %-5s %s\n", 'type', 'attribute', 'fault', 'seen by a router')
      out << ('-' * 78) << "\n"
      attributes.each do |r|
        cases = f[r.type] || []
        seen = routers_for(r, cases)
        out << format("%-4d %-28s %-5s %s\n", r.type,
                      r.klass.to_s.sub('BGP::', ''),
                      cases.empty? ? '--' : cases.size.to_s,
                      seen.empty? ? '-- never sent to one --' : seen.join(' '))
      end
      out
    end

    # Which routers have seen one attribute, as a list.
    #
    # **Why a fault case counts**: the RFC 7606 matrix sends every entry
    # of `BGP::Fault::CATALOG` to GoBGP and to FRR, so one case is one
    # measurement against each. An attribute with no case is in no lab
    # test unless a dedicated one names it, and `DIRECT` is that list.
    #
    # The summary's never-sent list reads this and not the fault count,
    # because the two differ by exactly ATTR_SET: it has no fault case
    # and a lab test of its own, so a list built from the count called
    # it unsent on the line after its own row said GoBGP had it.
    def routers_for(reg, cases)
      seen = cases.empty? ? [] : %w[gobgp frr]
      (seen + Array(DIRECT[reg.klass.to_s.sub('BGP::', '')])).uniq
    end

    def family_table
      out = +"Address families, as the build gate knows them\n\n"
      out << format("%-15s %-8s %-26s %-13s %-13s %s\n",
                    'family', 'safi', 'IANA name', 'gobgp', 'frr', 'gen')
      out << ('-' * 78) << "\n"
      family_slugs.each do |s|
        safis = families.select { |_, sa| slug(sa) == s }.collect { |_, sa| sa }.uniq
        v = vouches(s) || {}
        out << format("%-15s %-8s %-26s %-13s %-13s %s\n", s, safis.join(','),
                      IANA.safi_name(safis.first).to_s,
                      verdict(s, v[:gobgp], :gobgp), verdict(s, v[:frr], :frr),
                      gen_column(s))
      end
      out << <<~LEGEND

        both     the router encodes the family too, so its output feeds our decoder
        send     the router reads what we send; our decode side is not exercised
        absence  the router has no such family, so the test vouches for NOTHING
                 about our octets, only for how the router says so
        --       no lab test against that router
        gen      yes when bgp/gen has a generator, then the routers a
                 generated feed was sent to, whatever they made of it

        The number is how many lab files carry it. Read the document each
        family cites before trusting any of these: what a measurement
        proves is not the same from one row to the next.
      LEGEND
      out
    end

    # Whether bgp/gen has a generator, and which routers a generated feed
    # went to. The gobgp and frr columns say what a router vouches for;
    # this one says only that a feed reached it, so an absence router is
    # listed here too.
    def gen_column(slug)
      return '--' unless generator_slugs.include?(slug)
      (['yes'] + gen_routers(slug).collect(&:to_s)).join(' ')
    end

    def verdict(slug, v, router)
      n = router_tests_for(slug, router).size
      v.nil? ? '?' : (v == :none ? '--' : "#{v} (#{n})")
    end

    def summary
      f = faults_by_type
      with = attributes.count { |r| (f[r.type] || []).any? }
      fams = family_slugs
      measured = fams.count { |s|
        v = vouches(s) || {}
        [v[:gobgp], v[:frr]].any? { |x| x == :send || x == :both }
      }
      absence = fams.count { |s|
        v = vouches(s) || {}
        ![v[:gobgp], v[:frr]].any? { |x| x == :send || x == :both } &&
          [v[:gobgp], v[:frr]].any? { |x| x == :absence }
      }
      never = attributes.reject { |r| routers_for(r, f[r.type] || []).any? }
                        .collect { |r| r.klass.to_s.sub('BGP::', '') }
      out = +"Summary\n\n"
      out << "#{attributes.size} path attributes registered, " \
             "#{with} with a fault case, #{attributes.size - with} with none.\n"
      out << "#{fams.size} address families in the build gate: " \
             "#{measured} measured against a router, #{absence} where the " \
             "only\nmeasurement is the router's absence, " \
             "#{fams.size - measured - absence} not measured at all.\n"
      gens = fams.count { |s| generator_slugs.include?(s) }
      sent = fams.count { |s| !gen_routers(s).empty? }
      out << "#{gens} of them have a bgp/gen generator, #{sent} sent to a router by one.\n"
      out << "\n#{never.size} attributes have never been sent to a router:\n"
      never.each_slice(3) { |g| out << "  #{g.join('  ')}\n" }
      out << "\n#{BGP::Fault.names.size} fault cases in BGP::Fault::CATALOG.\n"
      out << "Round trip verdicts are not here: rake to_hash:status prints those.\n"
      out
    end

  end

end

print CoverageMatrix.report if $PROGRAM_NAME == __FILE__

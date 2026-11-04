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

module BGP
  module Sim

    # docs/console.md at the prompt: `guide` prints it, and `guide 4` or
    # `guide 'router'` prints one section.
    #
    # **It reads the Markdown and does not ship a second copy of it**, so
    # the guide a person reads at the prompt is the one CLAUDE.md asks to
    # keep true, and the one test/unit/sim/console_test.rb holds against
    # the code. The gem ships docs/ because `s.files` is `git ls-files`.
    #
    # **No gem renders it.** The library keeps one runtime dependency, so
    # this is the handful of Markdown shapes docs/console.md uses and no
    # more: headings, fenced code, a table, bold and inline code. Colour
    # only on a terminal; anywhere else the text comes back as written,
    # less the fence lines and the table's separator row.
    class Guide

      PATH = File.expand_path('../../docs/console.md', __dir__)

      BOLD = ["\e[1m", "\e[22m"].freeze
      CODE = ["\e[36m", "\e[39m"].freeze
      DIM  = ["\e[2m", "\e[22m"].freeze

      attr_reader :sections

      # text is the Markdown; color says whether to write escape codes.
      def initialize(text = File.read(PATH, :encoding => 'UTF-8'), color = false)
        @color = color
        @sections = split(text)
      end

      # The whole guide, rendered.
      def to_s
        render(@sections.collect(&:last).join)
      end

      # One section, chosen by its number or by a word in its heading, or
      # nil when none matches.
      def section(key)
        found = @sections.find { |title, _| numbered?(title, key) } ||
                @sections.find { |title, _| title.downcase.include?(key.to_s.downcase) }
        found && render(found.last)
      end

      # Every section heading, one per line, which is what an unknown key
      # is answered with.
      def contents
        @sections.collect(&:first).reject(&:empty?).collect { |t| "  #{t}\n" }.join
      end

      private

      # [heading, markdown] pairs, cut at each `## `. What comes before the
      # first one is the introduction and has an empty heading.
      def split(text)
        text.lines.slice_before { |l| l.start_with?('## ') }.collect do |lines|
          title = lines.first.start_with?('## ') ? lines.first.sub('## ', '').strip : ''
          [title, lines.join]
        end
      end

      def numbered?(title, key)
        key.is_a?(Integer) && title.start_with?("#{key}.")
      end

      def render(markdown)
        out = []
        table = []
        fence = false
        markdown.each_line(chomp: true) do |line|
          if line.start_with?('```')
            fence = !fence
            next
          end
          if fence
            out << "    #{style(DIM, line)}"
            next
          end
          if line.start_with?('|')
            table << line
            next
          end
          unless table.empty?
            out.concat(rows(table))
            table = []
          end
          out << if line =~ /\A#+ (.*)/
                   style(BOLD, plain(Regexp.last_match(1)))
                 else
                   inline(line)
                 end
        end
        out.concat(rows(table))
        out.collect { |l| "#{l}\n" }.join
      end

      # A Markdown table as aligned columns, with the separator row gone
      # and the header bold. Widths are counted before colour goes in.
      def rows(table)
        cells = table.reject { |l| l =~ /\A[|\s:-]+\z/ }.collect do |l|
          l.strip.sub(/\A\|/, '').sub(/\|\z/, '').split('|').collect { |c| plain(c.strip) }
        end
        return [] if cells.empty?
        # A ragged table is printed as written rather than guessed at.
        return table unless cells.collect(&:size).uniq.size == 1
        widths = cells.transpose.collect { |col| col.collect(&:size).max }
        cells.each_with_index.collect do |row, i|
          text = row.each_with_index.collect { |c, j| c.ljust(widths[j]) }.join('  ').rstrip
          '  ' + (i.zero? ? style(BOLD, text) : text)
        end
      end

      # Inline markup on a terminal: bold for `**`, colour for code.
      # Elsewhere the line is left as written.
      def inline(line)
        return line unless @color
        line.gsub(/\*\*(.+?)\*\*/) { style(BOLD, Regexp.last_match(1)) }
            .gsub(/`([^`]+)`/) { style(CODE, Regexp.last_match(1)) }
      end

      # The text with its markup taken out, for a heading or a table cell
      # whose width is measured.
      def plain(text)
        text.gsub(/\*\*(.+?)\*\*/, '\1').gsub(/`([^`]+)`/, '\1')
      end

      def style(pair, text)
        @color ? "#{pair[0]}#{text}#{pair[1]}" : text
      end
    end
  end
end

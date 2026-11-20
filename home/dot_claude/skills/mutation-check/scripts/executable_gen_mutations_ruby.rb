#!/usr/bin/env ruby
# frozen_string_literal: true

# Ruby のファイルを Prism で構文木にし、指定した行にあるノードを機械的に書き換えた変異を JSON で出す。
# gen_mutations.py が呼ぶ。標準入力に {"ファイル": [行番号, ...]} を受け取り、{"mutations": [...]} を返す。
#
# 変異は `offset`（ファイル先頭からのバイト位置）と old / new を持ち、run_mutations.py はその位置だけを
# 書き換える。書き換えた結果が構文エラーになる変異は、流しても何も確かめられないので出さない。

require "json"
require "prism"

COMPARISON = { :>= => %w[>], :<= => %w[<], :> => %w[>=], :< => %w[<=], :== => %w[!=], :!= => %w[==] }.freeze
ARITHMETIC = { :+ => "-", :- => "+", :* => "/", :/ => "*" }.freeze
METHOD_SWAP = {
  present?: "blank?", blank?: "present?", any?: "none?", none?: "any?", all?: "any?", empty?: "any?",
  min: "max", max: "min", min_by: "max_by", max_by: "min_by", first: "last", last: "first",
  floor: "ceil", ceil: "floor", select: "reject", reject: "select", filter: "reject",
}.freeze
# 呼び出しを外してレシーバーだけにする（引数もブロックも無いとき）
METHOD_DROP = %i[uniq compact distinct].freeze

UNDELETABLE = [
  Prism::LocalVariableWriteNode, Prism::LocalVariableOperatorWriteNode, Prism::LocalVariableOrWriteNode,
  Prism::LocalVariableAndWriteNode, Prism::MultiWriteNode, Prism::ConstantWriteNode,
  Prism::DefNode, Prism::ClassNode, Prism::ModuleNode,
].freeze

class Mutator < Prism::Visitor
  attr_reader :found

  def initialize(source, lines)
    super()
    @source = source
    @lines = lines
    @found = []
  end

  def visit_call_node(node)
    operator = node.message_loc
    if operator && node.receiver
      binary = node.arguments&.arguments&.size == 1 && node.call_operator_loc.nil?
      if binary && COMPARISON.key?(node.name)
        COMPARISON[node.name].each { |new| add("比較", operator, new) }
      elsif binary && ARITHMETIC.key?(node.name)
        add("算術", operator, ARITHMETIC[node.name])
      elsif node.name == :! && node.arguments.nil?
        add("否定", node.location, node.receiver.slice)
      elsif node.call_operator_loc
        add("メソッド", operator, METHOD_SWAP[node.name]) if METHOD_SWAP.key?(node.name)
        if METHOD_DROP.include?(node.name) && node.arguments.nil? && node.block.nil?
          add("呼び出しの削除", node.location, node.receiver.slice, at: operator, shown: ".#{node.name} → （消す）")
        end
        add("nil の扱い", node.call_operator_loc, ".") if node.safe_navigation?
      end
    end
    super
  end

  def visit_and_node(node)
    logical(node, node.operator == "&&" ? "||" : "or")
    super
  end

  def visit_or_node(node)
    logical(node, node.operator == "||" ? "&&" : "and")
    super
  end

  def visit_if_node(node)
    # 三項演算子には if_keyword_loc が無い。elsif は unless に替えられない
    condition(node, node.if_keyword_loc, node.if_keyword == "if" ? "unless" : nil)
    super
  end

  def visit_unless_node(node)
    condition(node, node.keyword_loc, "if")
    super
  end

  def visit_true_node(node)
    add("真偽", node.location, "false")
    super
  end

  def visit_false_node(node)
    add("真偽", node.location, "true")
    super
  end

  def visit_integer_node(node)
    return super unless node.slice.match?(/\A\d+\z/)

    add("数値", node.location, (node.value + 1).to_s)
    add("数値", node.location, "0") if node.value == 1
    super
  end

  def visit_statements_node(node)
    if node.body.size > 1
      node.body.each do |statement|
        # 定義や代入を消すと後ろの参照が NameError になるだけで、どのテストでも落ちる
        next if UNDELETABLE.any? { |type| statement.is_a?(type) }

        add("文の削除", statement.location, "")
      end
    end
    super
  end

  private

  def logical(node, swapped)
    add("論理", node.operator_loc, swapped)
    add("論理（左だけ）", node.location, node.left.slice, at: node.operator_loc)
    add("論理（右だけ）", node.location, node.right.slice, at: node.operator_loc)
  end

  def condition(node, keyword, swapped)
    add("条件", keyword, swapped) if keyword && swapped
    predicate = node.predicate
    return if predicate.is_a?(Prism::TrueNode) || predicate.is_a?(Prism::FalseNode)

    add("条件を true に", predicate.location, "true")
    add("条件を false に", predicate.location, "false")
  end

  # at: 対象の行かどうかを決める位置（省くと書き換える範囲の先頭）
  # shown: label に出す書き換えの要約（省くと old → new の先頭）
  def add(kind, location, new, at: location, shown: nil)
    return unless @lines.include?(at.start_line)

    old = location.slice
    return if old == new

    mutated = @source.byteslice(0, location.start_offset) + new.b + @source.byteslice(location.end_offset..)
    return unless Prism.parse(mutated).success?

    @found << {
      kind:, line: at.start_line, column: at.start_column + 1, offset: location.start_offset, old:, new:, shown:,
    }
  end
end

def short(text)
  first = text.lines.first.to_s.strip
  first = "#{first[0, 40]}…" if first.size > 40 || text.lines.size > 1
  first.empty? ? "（消す）" : first
end

def mutations_for(file, lines)
  source = File.binread(file)
  result = Prism.parse(source)
  unless result.success?
    warn "gen_mutations_ruby: #{file} を構文木にできないので飛ばす"
    return []
  end

  mutator = Mutator.new(source, lines)
  result.value.accept(mutator)
  mutator.found.uniq { |m| m.values_at(:offset, :old, :new) }.map do |m|
    old = m[:old].dup.force_encoding("UTF-8")
    new = m[:new].dup.force_encoding("UTF-8")
    {
      label: "auto/#{m[:kind]}: #{file}:#{m[:line]}:#{m[:column]} #{m[:shown] || "#{short(old)} → #{short(new)}"}",
      file:, offset: m[:offset], old:, new:,
    }
  end
end

targets = JSON.parse($stdin.read)
mutations = targets.sort.flat_map { |file, lines| mutations_for(file, lines) }
# 同じ位置の入れ子のノードで label が重なることがあるので、番号を振って一意にする
mutations.group_by { |m| m[:label] }.each_value do |same|
  same.drop(1).each_with_index { |m, i| m[:label] += " (#{i + 2})" }
end
puts JSON.pretty_generate(mutations:)

# Creates a _prettified_ version of a CST.

@enum(
    PLeaf,
    NEWLINE,
    SEMICOLON,
    WHITESPACE,
    PLACEHOLDER,
    NOTCODE,
    INLINECOMMENT,
    TRAILINGCOMMA,
    TRAILINGSEMICOLON,
)

mutable struct PTree
    typ::Union{CSTParser.Head,PLeaf}
    startline::Int
    endline::Int
    indent::Int
    len::Int
    val::Union{Nothing,AbstractString}
    nodes::Union{Nothing,Vector{PTree}}
    ref::Union{Nothing,Ref{CSTParser.EXPR}}
    force_nest::Bool
    extra_margin::Int
end

PTree(x::CSTParser.EXPR, indent::Integer) =
    PTree(x.typ, -1, -1, indent, 0, nothing, PTree[], Ref(x), false, 0)

function PTree(x::CSTParser.EXPR, startline::Integer, endline::Integer, val::AbstractString)
    PTree(x.typ, startline, endline, 0, length(val), val, nothing, Ref(x), false, 0)
end

function PTree(x::CSTParser.Head, startline::Integer, endline::Integer, val::AbstractString)
    PTree(x, startline, endline, 0, length(val), val, nothing, nothing, false, 0)
end

function Base.setindex!(pt::PTree, node::PTree, ind::Int)
    # pt.len = pt.len - pt.nodes[ind].len + node.len
    pt.nodes[ind] = node
end
Base.getindex(pt::PTree, inds...) = pt.nodes[inds...]
Base.lastindex(pt::PTree) = length(pt.nodes)


Newline(; length = 0, force_nest = false) =
    PTree(NEWLINE, -1, -1, 0, length, "\n", nothing, nothing, force_nest, 0)
Semicolon() = PTree(SEMICOLON, -1, -1, 0, 1, ";", nothing, nothing, false, 0)
TrailingComma() = PTree(TRAILINGCOMMA, -1, -1, 0, 0, "", nothing, nothing, false, 0)
TrailingSemicolon() =
    PTree(TRAILINGSEMICOLON, -1, -1, 0, 1, ";", nothing, nothing, false, 0)
Whitespace(n) = PTree(WHITESPACE, -1, -1, 0, n, " "^n, nothing, nothing, false, 0)
Placeholder(n) = PTree(PLACEHOLDER, -1, -1, 0, n, " "^n, nothing, nothing, false, 0)
Notcode(startline, endline) =
    PTree(NOTCODE, startline, endline, 0, 0, "", nothing, nothing, false, 0)
InlineComment(line) = PTree(INLINECOMMENT, line, line, 0, 0, "", nothing, nothing, false, 0)

Base.length(pt::PTree) = pt.len

is_leaf(pt::PTree) = pt.nodes === nothing
empty_start(pt::PTree) = pt.startline == 1 && pt.endline == 1 && pt.val == ""

is_punc(x) = CSTParser.ispunctuation(x)
is_end(x) = x.typ === CSTParser.KEYWORD && x.val == "end"
is_colon(x) = x.typ === CSTParser.OPERATOR && x.val == ":"
is_comma(pt::PTree) =
    (pt.typ === CSTParser.PUNCTUATION && pt.val == ",") || pt.typ === TRAILINGCOMMA
is_comment(pt::PTree) = pt.typ === INLINECOMMENT || pt.typ === NOTCODE

is_colon_op(x) =
    (
        x.typ === CSTParser.BinaryOpCall && x[2].kind === Tokens.COLON
    ) || x.typ === CSTParser.ColonOpCall

is_lazy_op(x) =
    x.typ === CSTParser.BinaryOpCall && (
        x[2].kind === Tokens.LAZY_OR || x[2].kind === Tokens.LAZY_AND
    )

# f a function which returns a bool
function parent_is(cst::CSTParser.EXPR, f; ignore_typs = [])
    p = cst.parent
    p === nothing && return false
    while p !== nothing && p.typ in ignore_typs
        p = p.parent
    end
    f(p)
end

# TODO: Remove once this is fixed in CSTParser.
# https://github.com/julia-vscode/CSTParser.jl/issues/108
function get_args(x::CSTParser.EXPR)
    if x.typ === CSTParser.MacroCall ||
       x.typ === CSTParser.TypedVcat || x.typ === CSTParser.Ref || x.typ === CSTParser.Curly
        return get_args(x.args[2:end])
    elseif x.typ === CSTParser.Parameters || x.typ === CSTParser.Braces ||
           x.typ === CSTParser.Vcat || x.typ === CSTParser.TupleH ||
           x.typ === CSTParser.Vect || x.typ === CSTParser.InvisBrackets
        return get_args(x.args)
    end
    CSTParser.get_args(x)
end

function get_args(args::Vector{CSTParser.EXPR})
    args0 = CSTParser.EXPR[]
    for arg in args
        CSTParser.ispunctuation(arg) && continue
        if CSTParser.typof(arg) === CSTParser.Parameters
            for j = 1:length(arg.args)
                parg = arg.args[j]
                CSTParser.ispunctuation(parg) && continue
                push!(args0, parg)
            end
        else
            push!(args0, arg)
        end
    end
    args0
end

function get_args(x::PTree)
    is_iterable(x) || error("get_args requires an iterable PTree type")
    sidx = findfirst(is_opener, x.nodes)
    sidx === nothing && (sidx = 1)
    args = PTree[]
    for i = sidx:length(x.nodes)
        arg = x.nodes[i]
        arg.typ === CSTParser.PUNCTUATION && continue
        arg.typ isa PLeaf && continue
        if arg.typ === CSTParser.Parameters
            for j = 1:length(arg.nodes)
                parg = arg.nodes[j]
                push!(args, parg)
            end
        else
            push!(args, arg)
        end
    end
    args
end

n_args(x) = length(get_args(x))

function add_node!(t::PTree, n::PTree, s::State; join_lines = false, max_padding = -1)
    if n.typ === SEMICOLON
        join_lines = true
        loc = s.offset > length(s.doc.text) && t.typ === CSTParser.TopLevel ?
            cursor_loc(s, s.offset - 1) : cursor_loc(s)
        for l = t.endline:loc[1]
            if has_semicolon(s.doc, l)
                # @info "found semicolon" l
                n.startline = l
                n.endline = l
                break
            end
        end
        # @info "" t.endline n.endline loc[1]

        # If there's no semicolon, treat it
        # as a PLeaf
        if n.startline == -1
            t.len += length(n)
            n.startline = t.startline
            n.endline = t.endline
            push!(t.nodes, n)
            return
        end
    elseif n.typ === TRAILINGCOMMA
        en = t.nodes[end]
        if en.typ === CSTParser.Generator || en.typ === CSTParser.Filter ||
           en.typ === CSTParser.Flatten || en.typ === CSTParser.MacroCall || (
            is_comma(en) && t.typ === CSTParser.TupleH && n_args(t.ref[]) == 1
        )
            # don't insert trailing comma in these cases
        elseif is_comma(en)
            t.nodes[end] = n
            t.len -= 1
        else
            t.len += length(n)
            n.startline = t.startline
            n.endline = t.endline
            push!(t.nodes, n)
        end
        return
    elseif n.typ === NOTCODE || n.typ === INLINECOMMENT
        push!(t.nodes, n)
        return
    elseif n.typ isa PLeaf
        t.len += length(n)
        n.startline = t.startline
        n.endline = t.endline
        push!(t.nodes, n)
        return
    end

    if n.typ === CSTParser.Block && length(n) == 0
        return
    elseif n.typ === CSTParser.Parameters
        if n_args(t.ref[]) == n_args(n.ref[])
            # There are no arguments prior to params
            # so we can remove the initial placeholder.
            idx = findfirst(n -> n.typ === PLACEHOLDER, t.nodes)
            idx !== nothing && deleteat!(t.nodes, idx)
        end
        add_node!(t, Semicolon(), s)
        if length(n.nodes) > 0
            multi_arg = n_args(t.ref[]) > 0
            multi_arg ? add_node!(t, Placeholder(1), s) : add_node!(t, Whitespace(1), s)
        end
    end

    if length(t.nodes) == 0
        t.startline = n.startline
        t.endline = n.endline
        t.len += length(n)
        push!(t.nodes, n)
        return
    end

    if !is_prev_newline(t.nodes[end])
        current_line = t.endline
        notcode_startline = current_line + 1
        notcode_endline = n.startline - 1
        nt = t.nodes[end].typ

        if notcode_startline <= notcode_endline && n.typ !== CSTParser.LITERAL
            # If there are comments in between node elements
            # nesting is forced in an effort to preserve them.
            t.force_nest = true

            # If the previous node type is WHITESPACE - reset it.
            # This fixes cases similar to the one shown in issue #51.
            nt === WHITESPACE && (t.nodes[end] = Whitespace(0))

            hs = hascomment(s.doc, current_line)
            hs && add_node!(t, InlineComment(current_line), s)
            if nt !== PLACEHOLDER
                add_node!(t, Newline(force_nest = true), s)
            elseif hs && nt === PLACEHOLDER
                # swap PLACEHOLDER (will be NEWLINE) with INLINECOMMENT node
                idx = length(t.nodes)
                t.nodes[idx-1], t.nodes[idx] = t.nodes[idx], t.nodes[idx-1]
            end
            add_node!(t, Notcode(notcode_startline, notcode_endline), s)
            add_node!(t, Newline(force_nest = true), s)
        elseif !join_lines
            hascomment(s.doc, current_line) && add_node!(t, InlineComment(current_line), s)
            add_node!(t, Newline(force_nest = true), s)
        elseif nt === PLACEHOLDER &&
               current_line != n.startline && hascomment(s.doc, current_line)
            t.force_nest = true
            add_node!(t, InlineComment(current_line), s)
            # swap PLACEHOLDER (will be NEWLINE) with INLINECOMMENT node
            idx = length(t.nodes)
            t.nodes[idx-1], t.nodes[idx] = t.nodes[idx], t.nodes[idx-1]
        end

        if n.typ === CSTParser.Parameters && n.force_nest
            t.force_nest = true
        end
    end

    if n.startline < t.startline || t.startline == -1
        t.startline = n.startline
    end
    if n.endline > t.endline || t.endline == -1
        t.endline = n.endline
    end

    if !join_lines && is_end(n)
        # end keyword isn't useful w.r.t margin lengths
    elseif t.typ === CSTParser.StringH
        # @info "insert literal into stringh" length(n) n n.indent + length(n) - t.indent t.indent n.indent

        # The length of this node is the length of
        # the longest string. The length of the string is
        # only considered "in the positive" when it's past
        # the hits the initial """ offset, i.e. `t.indent`.
        t.len = max(t.len, n.indent + length(n) - t.indent)
    elseif n.typ === CSTParser.StringH
        is_iterable(t) && n_args(t.ref[]) > 1 && (t.force_nest = true)
        t.len += length(n)
    elseif max_padding >= 0
        t.len = max(t.len, length(n) + max_padding)
    else
        t.len += length(n)
    end
    push!(t.nodes, n)
    nothing
end

function is_prev_newline(x::PTree)
    if x.typ === NEWLINE
        return true
    elseif is_leaf(x) || length(x.nodes) == 0
        return false
    end
    is_prev_newline(x.nodes[end])
end

"""
    `length_to(x::PTree, ntyps; start::Int = 1)`

Returns the length to any node type in `ntyps` based off the `start` index.
"""
function length_to(x::PTree, ntyps::Vector; start::Int = 1)
    x.typ in ntyps && return 0, true
    is_leaf(x) && return length(x), false
    len = 0
    for i = start:length(x.nodes)
        l, found = length_to(x.nodes[i], ntyps)
        len += l
        found && return len, found
    end
    return len, false
end

is_closer(x::PTree) =
    x.typ === CSTParser.PUNCTUATION && (x.val == "}" || x.val == ")" || x.val == "]")
is_closer(x::CSTParser.EXPR) =
    x.kind === Tokens.RBRACE || x.kind === Tokens.RPAREN || x.kind === Tokens.RSQUARE

is_opener(x::PTree) =
    x.typ === CSTParser.PUNCTUATION && (x.val == "{" || x.val == "(" || x.val == "[")
is_opener(x::CSTParser.EXPR) =
    x.kind === Tokens.LBRACE || x.kind === Tokens.LPAREN || x.kind === Tokens.LSQUARE

function pretty(x::CSTParser.EXPR, s::State)
    # @debug "" x.typ x.args
    if x.typ === CSTParser.IDENTIFIER
        return p_identifier(x, s)
    elseif x.typ === CSTParser.OPERATOR
        return p_operator(x, s)
    elseif x.typ === CSTParser.PUNCTUATION
        return p_punctuation(x, s)
    elseif x.typ === CSTParser.KEYWORD
        return p_keyword(x, s)
    elseif x.typ === CSTParser.LITERAL
        return p_literal(x, s)
    elseif x.typ === CSTParser.StringH
        return p_stringh(x, s)
    elseif x.typ === CSTParser.Block
        return p_block(x, s)
    elseif x.typ === CSTParser.ModuleH
        return p_module(x, s)
    elseif x.typ === CSTParser.BareModule
        return p_module(x, s)
    elseif x.typ === CSTParser.FunctionDef
        return p_function(x, s)
    elseif x.typ === CSTParser.Macro
        return p_function(x, s)
    elseif x.typ === CSTParser.Primitive
        return p_primitive(x, s)
    elseif x.typ === CSTParser.Struct
        return p_struct(x, s)
    elseif x.typ === CSTParser.Mutable
        return p_mutable(x, s)
    elseif x.typ === CSTParser.Abstract
        return p_abstract(x, s)
    elseif x.typ === CSTParser.Primitive
        return p_primitive(x, s)
    elseif x.typ === CSTParser.For
        return p_loop(x, s)
    elseif x.typ === CSTParser.While
        return p_loop(x, s)
    elseif x.typ === CSTParser.Do
        return p_do(x, s)
    elseif x.typ === CSTParser.If
        return p_if(x, s)
    elseif x.typ === CSTParser.Try
        return p_try(x, s)
    elseif x.typ === CSTParser.TopLevel
        return p_toplevel(x, s)
    elseif x.typ === CSTParser.Begin
        return p_begin(x, s)
    elseif x.typ === CSTParser.Quote
        return p_quote(x, s)
    elseif x.typ === CSTParser.Let
        return p_let(x, s)
    elseif x.typ === CSTParser.Vect
        return p_vect(x, s)
    elseif x.typ === CSTParser.Braces
        return p_braces(x, s)
    elseif x.typ === CSTParser.TupleH
        return p_tuple(x, s)
    elseif x.typ === CSTParser.InvisBrackets
        return p_invisbrackets(x, s)
    elseif x.typ === CSTParser.Curly
        return p_curly(x, s)
    elseif x.typ === CSTParser.Call
        return p_call(x, s)
    elseif x.typ === CSTParser.MacroCall
        return p_macrocall(x, s)
    elseif x.typ === CSTParser.WhereOpCall
        return p_wherecall(x, s)
    elseif x.typ === CSTParser.ConditionalOpCall
        return p_condcall(x, s)
    elseif x.typ === CSTParser.BinaryOpCall
        return p_binarycall(x, s)
    elseif x.typ === CSTParser.UnaryOpCall
        return p_unarycall(x, s)
    elseif x.typ === CSTParser.ChainOpCall
        return p_chaincall(x, s)
    elseif x.typ === CSTParser.ColonOpCall
        return p_coloncall(x, s)
    elseif x.typ === CSTParser.Comparison
        return p_chaincall(x, s)
    elseif x.typ === CSTParser.Kw
        return p_kw(x, s)
    elseif x.typ === CSTParser.Parameters
        return p_params(x, s)
    elseif x.typ === CSTParser.Local
        return p_vardef(x, s)
    elseif x.typ === CSTParser.Global
        return p_vardef(x, s)
    elseif x.typ === CSTParser.Const
        return p_vardef(x, s)
    elseif x.typ === CSTParser.Return
        return p_vardef(x, s)
    elseif x.typ === CSTParser.Import
        return p_import(x, s)
    elseif x.typ === CSTParser.ImportAll
        return p_import(x, s)
    elseif x.typ === CSTParser.Export
        return p_import(x, s)
    elseif x.typ === CSTParser.Using
        return p_import(x, s)
    elseif x.typ === CSTParser.Row
        return p_row(x, s)
    elseif x.typ === CSTParser.Vcat
        return p_vcat(x, s)
    elseif x.typ === CSTParser.TypedVcat
        return p_vcat(x, s)
    elseif x.typ === CSTParser.Hcat
        return p_hcat(x, s)
    elseif x.typ === CSTParser.TypedHcat
        return p_hcat(x, s)
    elseif x.typ === CSTParser.Ref
        return p_ref(x, s)
    elseif x.typ === CSTParser.Comprehension
        return p_vect(x, s)
    elseif x.typ === CSTParser.Generator
        return p_gen(x, s)
    elseif x.typ === CSTParser.Filter
        return p_gen(x, s)
    end

    t = PTree(x, nspaces(s))
    is_fileh = x.typ === CSTParser.FileH
    for a in x
        if a.kind === Tokens.NOTHING
            s.offset += a.fullspan
            continue
        end
        # @debug "" a a.typ
        add_node!(
            t,
            pretty(a, s),
            s,
            join_lines = !is_fileh,
            max_padding = is_fileh ? 0 : -1,
        )
    end
    t
end

function p_identifier(x, s)
    loc = cursor_loc(s)
    s.offset += x.fullspan
    PTree(x, loc[1], loc[1], x.val)
end

function p_operator(x, s)
    loc = cursor_loc(s)
    val = string(CSTParser.Expr(x))
    s.offset += x.fullspan
    PTree(x, loc[1], loc[1], val)
end

function p_keyword(x, s)
    loc = cursor_loc(s)
    val = x.kind === Tokens.ABSTRACT ? "abstract" :
        x.kind === Tokens.BAREMODULE ? "baremodule" :
        x.kind === Tokens.BEGIN ? "begin" :
        x.kind === Tokens.BREAK ? "break" :
        x.kind === Tokens.CATCH ? "catch" :
        x.kind === Tokens.CONST ? "const" :
        x.kind === Tokens.CONTINUE ? "continue" :
        x.kind === Tokens.NEW ? "new" :
        x.kind === Tokens.DO ? "do" :
        x.kind === Tokens.IF ? "if" :
        x.kind === Tokens.ELSEIF ? "elseif" :
        x.kind === Tokens.ELSE ? "else" :
        x.kind === Tokens.END ? "end" :
        x.kind === Tokens.EXPORT ? "export" :
        x.kind === Tokens.FINALLY ? "finally" :
        x.kind === Tokens.FOR ? "for" :
        x.kind === Tokens.FUNCTION ? "function" :
        x.kind === Tokens.GLOBAL ? "global" :
        x.kind === Tokens.IMPORT ? "import" :
        x.kind === Tokens.IMPORTALL ? "importall" :
        x.kind === Tokens.LET ? "let" :
        x.kind === Tokens.LOCAL ? "local" :
        x.kind === Tokens.MACRO ? "macro" :
        x.kind === Tokens.MODULE ? "module" :
        x.kind === Tokens.MUTABLE ? "mutable" :
        x.kind === Tokens.OUTER ? "outer " :
        x.kind === Tokens.PRIMITIVE ? "primitive" :
        x.kind === Tokens.QUOTE ? "quote" :
        x.kind === Tokens.RETURN ? "return" :
        x.kind === Tokens.STRUCT ? "struct" :
        x.kind === Tokens.TYPE ? "type" :
        x.kind === Tokens.TRY ? "try" :
        x.kind === Tokens.USING ? "using" : x.kind === Tokens.WHILE ? "while" : ""
    s.offset += x.fullspan
    PTree(x, loc[1], loc[1], val)
end

function p_punctuation(x, s)
    loc = cursor_loc(s)
    val = x.kind === Tokens.LPAREN ? "(" :
        x.kind === Tokens.LBRACE ? "{" :
        x.kind === Tokens.LSQUARE ? "[" :
        x.kind === Tokens.RPAREN ? ")" :
        x.kind === Tokens.RBRACE ? "}" :
        x.kind === Tokens.RSQUARE ? "]" :
        x.kind === Tokens.COMMA ? "," :
        x.kind === Tokens.SEMICOLON ? ";" :
        x.kind === Tokens.AT_SIGN ? "@" : x.kind === Tokens.DOT ? "." : ""
    s.offset += x.fullspan
    PTree(x, loc[1], loc[1], val)
end

function p_literal(x, s)
    loc = cursor_loc(s)
    if !is_str_or_cmd(x.kind)
        val = x.val
        if x.kind === Tokens.FLOAT && x.val[end] == '.'
            # If a floating point ends in `.`, add trailing zero.
            val *= '0'
        elseif x.kind === Tokens.FLOAT && x.val[1] == '.'
            val = '0' * val
        end
        s.offset += x.fullspan
        return PTree(x, loc[1], loc[1], val)
    end

    # Strings are unescaped by CSTParser
    # to mimic Meta.parse which makes reproducing
    # the correct output from the LITERAL value problematic.
    # So we'll just look at the source directly!
    str_info = get(s.doc.lit_strings, s.offset - 1, nothing)

    # Tokenize treats the `ix` part of r"^(=?[^=]+)=(.*)$"ix as an
    # IDENTIFIER where as CSTParser parses it as a LITERAL.
    # An IDENTIFIER won't show up in the string literal lookup table.
    if str_info === nothing && (
        x.parent.typ === CSTParser.x_Str || x.parent.typ === CSTParser.x_Cmd
    )
        s.offset += x.fullspan
        return PTree(x, loc[1], loc[1], x.val)
    end

    startline, endline, str = str_info
    # @debug "" loc startline endline str

    s.offset += x.fullspan

    lines = split(str, "\n")

    if length(lines) == 1
        return PTree(x, loc[1], loc[1], lines[1])
    end

    sidx = loc[2]
    for l in lines[2:end]
        fc = findfirst(c -> !isspace(c), l)
        if fc !== nothing
            sidx = min(sidx, fc)
        end
    end

    # @debug "" lines x.val loc loc[2] sidx

    t = PTree(CSTParser.StringH, -1, -1, loc[2] - 1, 0, nothing, PTree[], Ref(x), false, 0)
    for (i, l) in enumerate(lines)
        ln = startline + i - 1
        l = i == 1 ? l : l[sidx:end]
        tt = PTree(
            CSTParser.LITERAL,
            ln,
            ln,
            sidx - 1,
            length(l),
            l,
            nothing,
            nothing,
            false,
            0,
        )
        add_node!(t, tt, s)
    end
    t
end

# StringH
function p_stringh(x, s)
    loc = cursor_loc(s)
    startline, endline, str = s.doc.lit_strings[s.offset-1]

    s.offset += x.fullspan

    lines = split(str, "\n")

    if length(lines) == 1
        t = PTree(x, startline, startline, lines[1])
        t.typ = CSTParser.LITERAL
        return t
    end

    sidx = loc[2]
    for l in lines[2:end]
        fc = findfirst(c -> !isspace(c), l)
        if fc !== nothing
            sidx = min(sidx, fc)
        end
    end

    # @debug "" lines x.val loc loc[2] sidx

    t = PTree(x, loc[2] - 1)
    for (i, l) in enumerate(lines)
        ln = startline + i - 1
        l = i == 1 ? l : l[sidx:end]
        tt = PTree(
            CSTParser.LITERAL,
            ln,
            ln,
            sidx - 1,
            length(l),
            l,
            nothing,
            nothing,
            false,
            0,
        )
        add_node!(t, tt, s)
    end
    t
end


# MacroCall
function p_macrocall(x, s)
    t = PTree(x, nspaces(s))
    if x.args[1].typ === CSTParser.GlobalRefDoc
        # x.args[1] is empty and fullspan is 0 so we can skip it
        if x.args[2].typ === CSTParser.LITERAL
            add_node!(t, p_literal(x.args[2], s), s, max_padding = 0)
        elseif x.args[2].typ == CSTParser.StringH
            add_node!(t, p_stringh(x.args[2], s), s)
        end
        add_node!(t, pretty(x.args[3], s), s, max_padding = 0)
        return t
    end

    args = get_args(x)
    nest = length(args) > 0 && !(length(args) == 1 && unnestable_arg(args[1]))
    has_closer = is_closer(x.args[end])

    # @info "" has_closer

    # same as CSTParser.Call but whitespace sensitive
    for (i, a) in enumerate(x)
        n = pretty(a, s)
        if a.typ === CSTParser.MacroName
            if a.fullspan - a.span > 0 && length(x) > 1
                add_node!(t, n, s, join_lines = true)
                add_node!(t, Whitespace(1), s)
            else
                # assumes the next argument is a brace of some sort
                add_node!(t, n, s, join_lines = true)
            end
        elseif is_opener(n) && nest
            add_node!(t, n, s, join_lines = true)
            add_node!(t, Placeholder(0), s)
        elseif is_closer(n) && nest
            add_node!(t, Placeholder(0), s)
            add_node!(t, n, s, join_lines = true)
        elseif CSTParser.is_comma(a) && i < length(x) && !is_punc(x.args[i+1])
            add_node!(t, n, s, join_lines = true)
            add_node!(t, Placeholder(1), s)
        elseif a.fullspan - a.span > 0
            if has_closer && i < length(x) - 1
                add_node!(t, n, s, join_lines = true)
                if x.args[i+1].typ !== CSTParser.Parameters
                    add_node!(t, Whitespace(1), s)
                end
            elseif !has_closer && i < length(x)
                add_node!(t, n, s, join_lines = true)
                add_node!(t, Whitespace(1), s)
            else
                add_node!(t, n, s, join_lines = true)
            end
        else
            add_node!(t, n, s, join_lines = true)
        end
    end
    t
end

# Block
# length Block is the length of the longest expr
function p_block(x, s; ignore_single_line = false, from_quote = false, join_body = false)
    t = PTree(x, nspaces(s))
    single_line = ignore_single_line ? false :
        cursor_loc(s)[1] == cursor_loc(s, s.offset + x.span - 1)[1]

    # @info "" from_quote single_line ignore_single_line join_body
    for (i, a) in enumerate(x)
        n = pretty(a, s)
        if from_quote && !single_line
            if i == 1 || CSTParser.is_comma(a)
                add_node!(t, n, s, join_lines = true)
            elseif CSTParser.is_comma(x.args[i-1])
                add_node!(t, Whitespace(1), s)
                add_node!(t, n, s, join_lines = true)
            else
                add_node!(t, Semicolon(), s)
                add_node!(t, n, s, max_padding = 0)
            end
        elseif single_line
            if i == 1 || CSTParser.is_comma(a)
                add_node!(t, n, s, join_lines = true)
            elseif CSTParser.is_comma(x.args[i-1])
                add_node!(t, Placeholder(1), s)
                add_node!(t, n, s, join_lines = true)
            else
                add_node!(t, Semicolon(), s)
                add_node!(t, Whitespace(1), s)
                add_node!(t, n, s, join_lines = true)
            end
        else
            if i < length(x) && CSTParser.is_comma(a) && is_punc(x.args[i+1])
                add_node!(t, n, s, join_lines = true)
            elseif CSTParser.is_comma(a) && i != length(x)
                add_node!(t, n, s, join_lines = true)
                join_body && add_node!(t, Placeholder(1), s)
            elseif join_body
                add_node!(t, n, s, join_lines = true)
            else
                add_node!(t, n, s, max_padding = 0)
            end
        end
    end
    # @info "" t.typ length(t)
    t
end

# Abstract
function p_abstract(x, s)
    t = PTree(x, nspaces(s))
    add_node!(t, pretty(x.args[1], s), s)
    add_node!(t, Whitespace(1), s)
    add_node!(t, pretty(x.args[2], s), s, join_lines = true)
    add_node!(t, Whitespace(1), s)
    add_node!(t, pretty(x.args[3], s), s, join_lines = true)
    add_node!(t, Whitespace(1), s)
    add_node!(t, pretty(x.args[4], s), s, join_lines = true)
    t
end

# Primitive
function p_primitive(x, s)
    t = PTree(x, nspaces(s))
    add_node!(t, pretty(x.args[1], s), s)
    add_node!(t, Whitespace(1), s)
    add_node!(t, pretty(x.args[2], s), s, join_lines = true)
    add_node!(t, Whitespace(1), s)
    add_node!(t, pretty(x.args[3], s), s, join_lines = true)
    add_node!(t, Whitespace(1), s)
    add_node!(t, pretty(x.args[4], s), s, join_lines = true)
    add_node!(t, Whitespace(1), s)
    add_node!(t, pretty(x.args[5], s), s, join_lines = true)
    t
end

# FunctionDef/Macro
function p_function(x, s)
    t = PTree(x, nspaces(s))
    add_node!(t, pretty(x.args[1], s), s)
    add_node!(t, Whitespace(1), s)
    add_node!(t, pretty(x.args[2], s), s, join_lines = true)
    if length(x) > 3
        if x.args[3].fullspan == 0
            add_node!(t, Whitespace(1), s)
            add_node!(t, pretty(x.args[4], s), s, join_lines = true)
        else
            s.indent += s.indent_size
            add_node!(
                t,
                p_block(x.args[3], s, ignore_single_line = true),
                s,
                max_padding = s.indent_size,
            )
            s.indent -= s.indent_size
            add_node!(t, pretty(x.args[4], s), s)
        end
    else
        # function stub, i.e. "function foo end"
        # this should be on one line
        add_node!(t, Whitespace(1), s)
        add_node!(t, pretty(x.args[3], s), s, join_lines = true)
    end
    t
end

# Struct
function p_struct(x, s)
    t = PTree(x, nspaces(s))
    add_node!(t, pretty(x.args[1], s), s)
    add_node!(t, Whitespace(1), s)
    add_node!(t, pretty(x.args[2], s), s, join_lines = true)
    if x.args[3].fullspan == 0
        add_node!(t, Whitespace(1), s)
        add_node!(t, pretty(x.args[4], s), s, join_lines = true)
    else
        s.indent += s.indent_size
        add_node!(
            t,
            p_block(x.args[3], s, ignore_single_line = true),
            s,
            max_padding = s.indent_size,
        )
        s.indent -= s.indent_size
        add_node!(t, pretty(x.args[4], s), s)
    end
    t
end

# Mutable
function p_mutable(x, s)
    t = PTree(x, nspaces(s))
    add_node!(t, pretty(x.args[1], s), s)
    add_node!(t, Whitespace(1), s)
    add_node!(t, pretty(x.args[2], s), s, join_lines = true)
    add_node!(t, Whitespace(1), s)
    add_node!(t, pretty(x.args[3], s), s, join_lines = true)
    if x.args[4].fullspan == 0
        add_node!(t, Whitespace(1), s)
        add_node!(t, pretty(x.args[5], s), s, join_lines = true)
    else
        s.indent += s.indent_size
        add_node!(
            t,
            p_block(x.args[4], s, ignore_single_line = true),
            s,
            max_padding = s.indent_size,
        )
        s.indent -= s.indent_size
        add_node!(t, pretty(x.args[5], s), s)
    end
    t
end

# ModuleH/BareModule
function p_module(x, s)
    t = PTree(x, nspaces(s))
    add_node!(t, pretty(x.args[1], s), s)
    add_node!(t, Whitespace(1), s)
    add_node!(t, pretty(x.args[2], s), s, join_lines = true)
    if x.args[3].fullspan == 0
        add_node!(t, Whitespace(1), s)
        add_node!(t, pretty(x.args[4], s), s, join_lines = true)
    else
        add_node!(t, pretty(x.args[3], s), s, max_padding = 0)
        add_node!(t, pretty(x.args[4], s), s)
    end
    t
end

# Const/Local/Global/Return
function p_vardef(x, s)
    t = PTree(x, nspaces(s))
    add_node!(t, pretty(x.args[1], s), s)
    if x.args[2].fullspan != 0
        for a in x.args[2:end]
            add_node!(t, Whitespace(1), s)
            add_node!(t, pretty(a, s), s, join_lines = true)
        end
    end
    t
end

# TopLevel
function p_toplevel(x, s)
    t = PTree(x, nspaces(s))
    for a in x.args
        if a.kind === Tokens.NOTHING
            s.offset += a.fullspan
            continue
        end
        add_node!(t, pretty(a, s), s, max_padding = s.indent_size)
        add_node!(t, Semicolon(), s)
    end
    t
end

# Begin
function p_begin(x, s)
    t = PTree(x, nspaces(s))
    add_node!(t, pretty(x.args[1], s), s)
    if x.args[2].fullspan == 0
        add_node!(t, Whitespace(1), s)
        add_node!(t, pretty(x.args[3], s), s, join_lines = true)
    else
        s.indent += s.indent_size
        add_node!(
            t,
            p_block(x.args[2], s, ignore_single_line = true),
            s,
            max_padding = s.indent_size,
        )
        s.indent -= s.indent_size
        add_node!(t, pretty(x.args[3], s), s)
    end
    t
end

# Quote
function p_quote(x, s)
    t = PTree(x, nspaces(s))
    if x.args[1].typ === CSTParser.KEYWORD && x.args[1].kind === Tokens.QUOTE
        add_node!(t, pretty(x.args[1], s), s)
        if x.args[2].fullspan == 0
            add_node!(t, Whitespace(1), s)
            add_node!(t, pretty(x.args[3], s), s, join_lines = true)
        else
            s.indent += s.indent_size
            add_node!(
                t,
                p_block(x.args[2], s, ignore_single_line = true),
                s,
                max_padding = s.indent_size,
            )
            s.indent -= s.indent_size
            add_node!(t, pretty(x.args[3], s), s)
        end
    else
        for a in x.args
            add_node!(t, pretty(a, s), s, join_lines = true)
        end
    end
    t
end

# Let
#
# two forms:
#
# let var1 = value1, var2
#     body
# end
#
# y, back = let
#     body
# end
function p_let(x, s)
    t = PTree(x, nspaces(s))
    add_node!(t, pretty(x.args[1], s), s)
    if length(x.args) > 3
        add_node!(t, Whitespace(1), s)
        s.indent += s.indent_size
        if x.args[2].typ === CSTParser.Block
            add_node!(t, p_block(x.args[2], s, join_body = true), s, join_lines = true)
        else
            add_node!(t, pretty(x.args[2], s), s, join_lines = true)
        end
        s.indent -= s.indent_size
        idx = length(t.nodes)
        s.indent += s.indent_size
        add_node!(
            t,
            p_block(x.args[3], s, ignore_single_line = true),
            s,
            max_padding = s.indent_size,
        )
        s.indent -= s.indent_size
        # Possible newline after args if nested to act as a separator
        # to the block body.
        if x.args[2].typ === CSTParser.Block && t.nodes[end-2].typ !== NOTCODE
            add_node!(t.nodes[idx], Placeholder(0), s)
        end
        add_node!(t, pretty(x.args[end], s), s)
    else
        s.indent += s.indent_size
        add_node!(t, p_block(x.args[2], s, ignore_single_line = true), s)
        s.indent -= s.indent_size
        add_node!(t, pretty(x.args[end], s), s)
    end
    t
end



# Transforms
#
# for i = iter body end
#
# =>
#
# for i in iter body end
#
# AND
#
# for i in 1:10 body end
#
# =>
#
# for i = 1:10 body end
#
# https://github.com/domluna/JuliaFormatter.jl/issues/34
function eq_to_in_normalization!(x, always_for_in)
    if x.typ === CSTParser.BinaryOpCall
        op = x.args[2]
        arg2 = x.args[3]

        if always_for_in
            x.args[2].kind = Tokens.IN
            return
        end

        if op.kind === Tokens.EQ && !is_colon_op(arg2)
            x.args[2].kind = Tokens.IN
        elseif op.kind === Tokens.IN && is_colon_op(arg2)
            x.args[2].kind = Tokens.EQ
        end
    elseif x.typ === CSTParser.Block || x.typ === CSTParser.InvisBrackets
        for a in x.args
            eq_to_in_normalization!(a, always_for_in)
        end
    end
end

# For/While
function p_loop(x, s)
    t = PTree(x, nspaces(s))
    add_node!(t, pretty(x.args[1], s), s)
    add_node!(t, Whitespace(1), s)
    if x.args[1].kind === Tokens.FOR
        eq_to_in_normalization!(x.args[2], s.always_for_in)
    end
    if x.args[2].typ === CSTParser.Block
        add_node!(t, p_block(x.args[2], s, join_body = true), s, join_lines = true)
    else
        add_node!(t, pretty(x.args[2], s), s, join_lines = true)
    end
    idx = length(t.nodes)
    s.indent += s.indent_size
    add_node!(
        t,
        p_block(x.args[3], s, ignore_single_line = true),
        s,
        max_padding = s.indent_size,
    )
    s.indent -= s.indent_size

    # Possible newline after args if nested to act as a separator
    # to the block body.
    if x.args[2].typ === CSTParser.Block && t.nodes[end-2].typ !== NOTCODE
        add_node!(t.nodes[idx], Placeholder(0), s)
    end
    add_node!(t, pretty(x.args[4], s), s)
    t
end

# Do
function p_do(x, s)
    # @info "" s.indent_size
    t = PTree(x, nspaces(s))
    add_node!(t, pretty(x.args[1], s), s)
    add_node!(t, Whitespace(1), s)
    add_node!(t, pretty(x.args[2], s), s, join_lines = true)
    if x.args[3].fullspan != 0
        add_node!(t, Whitespace(1), s)
        add_node!(t, pretty(x.args[3], s), s, join_lines = true)
    end
    if x.args[4].typ === CSTParser.Block
        s.indent += s.indent_size
        add_node!(
            t,
            p_block(x.args[4], s, ignore_single_line = true),
            s,
            max_padding = s.indent_size,
        )
        s.indent -= s.indent_size
    end
    add_node!(t, pretty(x.args[end], s), s)
    t
end

# Try
function p_try(x, s)
    t = PTree(x, nspaces(s))
    for a in x.args
        if a.fullspan == 0
        elseif a.typ === CSTParser.KEYWORD
            add_node!(t, pretty(a, s), s, max_padding = 0)
        elseif a.typ === CSTParser.Block
            s.indent += s.indent_size
            add_node!(
                t,
                p_block(a, s, ignore_single_line = true),
                s,
                max_padding = s.indent_size,
            )
            s.indent -= s.indent_size
        else
            len = length(t)
            add_node!(t, Whitespace(1), s)
            n = pretty(a, s)
            # "catch n"
            t.len = max(len, 5 + 1 + length(n))
            add_node!(t, n, s, join_lines = true, max_padding = 0)
        end
    end
    t
end

# If
function p_if(x, s)
    t = PTree(x, nspaces(s))
    if x.args[1].typ === CSTParser.KEYWORD && x.args[1].kind === Tokens.IF
        add_node!(t, pretty(x.args[1], s), s)
        add_node!(t, Whitespace(1), s)
        add_node!(t, pretty(x.args[2], s), s, join_lines = true)
        s.indent += s.indent_size
        add_node!(
            t,
            p_block(x.args[3], s, ignore_single_line = true),
            s,
            max_padding = s.indent_size,
        )
        s.indent -= s.indent_size

        len = length(t)
        if length(x.args) > 4
            add_node!(t, pretty(x.args[4], s), s, max_padding = 0)
            if x.args[4].kind === Tokens.ELSEIF
                add_node!(t, Whitespace(1), s)
                n = pretty(x.args[5], s)
                add_node!(t, n, s, join_lines = true)
                # "elseif n"
                t.len = max(len, length(n))
            else
                # ELSE KEYWORD
                s.indent += s.indent_size
                add_node!(
                    t,
                    p_block(x.args[5], s, ignore_single_line = true),
                    s,
                    max_padding = s.indent_size,
                )
                s.indent -= s.indent_size
            end
        end
        # END KEYWORD
        add_node!(t, pretty(x.args[end], s), s)
    else
        # "cond" part of "elseif cond"
        t.len += 7
        add_node!(t, pretty(x.args[1], s), s)

        s.indent += s.indent_size
        add_node!(
            t,
            p_block(x.args[2], s, ignore_single_line = true),
            s,
            max_padding = s.indent_size,
        )
        s.indent -= s.indent_size

        len = length(t)
        if length(x.args) > 2
            # this either else or elseif keyword
            add_node!(t, pretty(x.args[3], s), s, max_padding = 0)

            if x.args[3].kind === Tokens.ELSEIF
                add_node!(t, Whitespace(1), s)
                n = pretty(x.args[4], s)
                add_node!(t, n, s, join_lines = true)
                # "elseif n"
                t.len = max(len, length(n))
            else
                s.indent += s.indent_size
                add_node!(
                    t,
                    p_block(x.args[4], s, ignore_single_line = true),
                    s,
                    max_padding = s.indent_size,
                )
                s.indent -= s.indent_size
            end
        end
    end
    t
end

# ChainOpCall/Comparison
function p_chaincall(x, s; nonest = false, nospace = false)
    t = PTree(x, nspaces(s))
    for (i, a) in enumerate(x)
        n = pretty(a, s)
        if a.typ === CSTParser.OPERATOR
            !nospace && add_node!(t, Whitespace(1), s)
            add_node!(t, n, s, join_lines = true)
            if !(nospace && nonest)
                add_node!(t, Placeholder(1), s)
            end
        elseif i == length(x) - 1 && is_punc(a) && is_punc(x.args[i+1])
            add_node!(t, n, s, join_lines = true)
        else
            add_node!(t, n, s, join_lines = true)
        end
    end
    t
end

# ColonOpCall
function p_coloncall(x, s)
    t = PTree(x, nspaces(s))
    for a in x
        if a.typ === CSTParser.BinaryOpCall
            n = p_binarycall(a, s, nonest = true, nospace = true)
        else
            n = pretty(a, s)
        end
        add_node!(t, n, s, join_lines = true)
    end
    t
end

# Kw
function p_kw(x, s)
    t = PTree(x, nspaces(s))
    for a in x
        if a.kind === Tokens.EQ
            add_node!(t, Whitespace(1), s)
            add_node!(t, pretty(a, s), s, join_lines = true)
            add_node!(t, Whitespace(1), s)
        else
            add_node!(t, pretty(a, s), s, join_lines = true)
        end
    end
    t
end

is_str(x) = is_str_or_cmd(x.kind) || x.typ === CSTParser.StringH

is_iterable(x) =
    x.typ === CSTParser.TupleH || x.typ === CSTParser.Vect ||
    x.typ === CSTParser.Vcat || x.typ === CSTParser.Braces || x.typ === CSTParser.Call ||
    x.typ === CSTParser.Curly || x.typ === CSTParser.Comprehension ||
    x.typ === CSTParser.MacroCall || x.typ === CSTParser.InvisBrackets ||
    x.typ === CSTParser.Ref || x.typ === CSTParser.TypedVcat

is_block(x::CSTParser.EXPR) =
    x.typ === CSTParser.If || x.typ === CSTParser.Do || x.typ === CSTParser.Try ||
    x.typ === CSTParser.For || x.typ === CSTParser.While || x.typ === CSTParser.Let

nest_assignment(x::CSTParser.EXPR) = CSTParser.precedence(x[2].kind) == 1

unnestable_arg(x) =
    is_iterable(x) || is_str(x) || x.typ === CSTParser.LITERAL || (
        x.typ === CSTParser.BinaryOpCall && x[2].kind === Tokens.DOT
    )

function nestable(x::CSTParser.EXPR)
    CSTParser.defines_function(x) && x[1].typ !== CSTParser.UnaryOpCall && return true
    nest_assignment(x) && !is_str(x[3]) && return true
    if x[1].typ === CSTParser.InvisBrackets || x[3].typ === CSTParser.InvisBrackets
        return false
    end
    x[2].kind === Tokens.ANON_FUNC && return false
    x[2].kind === Tokens.PAIR_ARROW && return false
    CSTParser.precedence(x[2]) in (1, 6) && return false
    true
end

function nest_arg2(x::CSTParser.EXPR)
    if CSTParser.defines_function(x)
        arg2 = x.args[3]
        arg2.typ === CSTParser.Block && (arg2 = arg2.args[1])
        return is_block(arg2)
    end
    false
end

# BinaryOpCall
function p_binarycall(x, s; nonest = false, nospace = false)
    t = PTree(x, nspaces(s))
    op = x.args[2]
    nonest = nonest || op.kind === Tokens.COLON
    if x.parent.typ === CSTParser.Curly && op.kind in (Tokens.ISSUBTYPE, Tokens.ISSUPERTYPE)
        nospace = true
    elseif op.kind === Tokens.COLON
        nospace = true
    end

    if x.args[1].typ === CSTParser.BinaryOpCall
        add_node!(t, p_binarycall(x.args[1], s, nonest = nonest, nospace = nospace), s)
    elseif x.args[1].typ === CSTParser.InvisBrackets
        add_node!(t, p_invisbrackets(x.args[1], s, nonest = nonest, nospace = nospace), s)
    elseif x.args[1].typ === CSTParser.ChainOpCall
        add_node!(t, p_chaincall(x.args[1], s, nonest = nonest, nospace = nospace), s)
    else
        add_node!(t, pretty(x.args[1], s), s)
    end

    narg2 = nest_arg2(x)
    narg2 && (t.force_nest = true)
    nest = (nestable(x) && !nonest) || narg2
    # @info "" nestable(x) !nonest narg2 nest x[2]

    if op.fullspan == 0 && x.args[3].typ === CSTParser.IDENTIFIER
        # do nothing
    elseif op.kind === Tokens.EX_OR
        add_node!(t, Whitespace(1), s)
        add_node!(t, pretty(op, s), s, join_lines = true)
    elseif op.kind === Tokens.CIRCUMFLEX_ACCENT && op.dot
        add_node!(t, Whitespace(1), s)
        add_node!(t, pretty(op, s), s, join_lines = true)
        nest ? add_node!(t, Placeholder(1), s) : add_node!(t, Whitespace(1), s)
    elseif (
        nospace || (
            CSTParser.precedence(op) in (8, 13, 14, 16) && op.kind !== Tokens.ANON_FUNC
        )
    ) && op.kind !== Tokens.IN
        add_node!(t, pretty(op, s), s, join_lines = true)
    else
        add_node!(t, Whitespace(1), s)
        add_node!(t, pretty(op, s), s, join_lines = true)
        nest ? add_node!(t, Placeholder(1), s) : add_node!(t, Whitespace(1), s)
    end


    if x.args[3].typ === CSTParser.BinaryOpCall
        n = p_binarycall(x.args[3], s, nonest = nonest, nospace = nospace)
    elseif x.args[3].typ === CSTParser.InvisBrackets
        n = p_invisbrackets(x.args[3], s, nonest = nonest, nospace = nospace)
    elseif x.args[3].typ === CSTParser.ChainOpCall
        n = p_chaincall(x.args[3], s, nonest = nonest, nospace = nospace)
    else
        n = pretty(x.args[3], s)
    end
    add_node!(t, n, s, join_lines = true)

    if nest
        # for indent, will be converted to `indent_size` if needed
        insert!(t.nodes, length(t.nodes), Placeholder(0))
    end
    t
end

# WhereOpCall
# A where B
function p_wherecall(x, s)
    t = PTree(x, nspaces(s))
    add_node!(t, pretty(x.args[1], s), s)

    add_node!(t, Whitespace(1), s)
    add_node!(t, pretty(x.args[2], s), s, join_lines = true)
    add_node!(t, Whitespace(1), s)

    # Used to mark where `B` starts.
    add_node!(t, Placeholder(0), s)

    nest = length(CSTParser.get_where_params(x)) > 0
    args = get_args(x.args[3:end])
    # nest = length(args) > 0 && !(length(CSTParser.get_where_params(x)) == 1 && unnestable_arg(x[1]))
    nest = length(args) > 0 && !(length(args) == 1 && unnestable_arg(args[1]))
    add_braces =
        !CSTParser.is_lbrace(x.args[3]) &&
        x.parent.typ !== CSTParser.Curly && x.args[3].typ !== CSTParser.Curly

    add_braces && add_node!(
        t,
        PTree(CSTParser.PUNCTUATION, t.endline, t.endline, "{"),
        s,
        join_lines = true,
    )

    # @debug "" nest in_braces x.args[3].val == "{" x.args[end].val
    for (i, a) in enumerate(x.args[3:end])
        if is_opener(a) && nest
            add_node!(t, pretty(a, s), s, join_lines = true)
            add_node!(t, Placeholder(0), s)
            s.indent += s.indent_size
        elseif is_closer(a) && nest
            add_node!(t, TrailingComma(), s)
            add_node!(t, Placeholder(0), s)
            add_node!(t, pretty(a, s), s, join_lines = true)
            s.indent -= s.indent_size
        elseif CSTParser.is_comma(a) && !is_punc(x.args[i+3])
            add_node!(t, pretty(a, s), s, join_lines = true)
            add_node!(t, Placeholder(0), s)
        elseif a.typ === CSTParser.BinaryOpCall
            add_node!(t, p_binarycall(a, s, nospace = true), s, join_lines = true)
        else
            add_node!(t, pretty(a, s), s, join_lines = true)
        end
    end
    add_braces && add_node!(
        t,
        PTree(CSTParser.PUNCTUATION, t.endline, t.endline, "}"),
        s,
        join_lines = true,
    )
    t
end

# Conditional
function p_condcall(x, s)
    t = PTree(x, nspaces(s))
    add_node!(t, pretty(x.args[1], s), s)
    add_node!(t, Whitespace(1), s)
    add_node!(t, pretty(x.args[2], s), s, join_lines = true)
    add_node!(t, Placeholder(1), s)

    add_node!(t, pretty(x.args[3], s), s, join_lines = true)
    add_node!(t, Whitespace(1), s)
    add_node!(t, pretty(x.args[4], s), s, join_lines = true)
    add_node!(t, Placeholder(1), s)

    add_node!(t, pretty(x.args[5], s), s, join_lines = true)
    t
end

# UnaryOpCall
function p_unarycall(x, s)
    t = PTree(x, nspaces(s))
    add_node!(t, pretty(x.args[1], s), s)
    add_node!(t, pretty(x.args[2], s), s, join_lines = true)
    t
end

function p_curly(x, s)
    t = PTree(x, nspaces(s))
    add_node!(t, pretty(x.args[1], s), s)
    add_node!(t, pretty(x.args[2], s), s, join_lines = true)

    args = get_args(x)
    nest = length(args) > 0 && !(length(args) == 1 && unnestable_arg(x[1]))

    if nest
        add_node!(t, Placeholder(0), s)
    end

    for (i, a) in enumerate(x.args[3:end])
        if i + 2 == length(x) && nest
            add_node!(t, TrailingComma(), s)
            add_node!(t, Placeholder(0), s)
            add_node!(t, pretty(a, s), s, join_lines = true)
        elseif CSTParser.is_comma(a) && i < length(x) - 3 && !is_punc(x.args[i+3])
            add_node!(t, pretty(a, s), s, join_lines = true)
            add_node!(t, Placeholder(0), s)
        else
            add_node!(t, pretty(a, s), s, join_lines = true)
        end
    end
    t
end

function p_call(x, s)
    t = PTree(x, nspaces(s))
    add_node!(t, pretty(x.args[1], s), s)
    add_node!(t, pretty(x.args[2], s), s, join_lines = true)

    args = get_args(x)
    nest = length(args) > 0 && !(length(args) == 1 && unnestable_arg(args[1]))

    if nest
        add_node!(t, Placeholder(0), s)
    end

    for (i, a) in enumerate(x.args[3:end])
        if i + 2 == length(x) && nest
            add_node!(t, TrailingComma(), s)
            add_node!(t, Placeholder(0), s)
            add_node!(t, pretty(a, s), s, join_lines = true)
        elseif CSTParser.is_comma(a) && i < length(x) - 3 && !is_punc(x.args[i+3])
            add_node!(t, pretty(a, s), s, join_lines = true)
            add_node!(t, Placeholder(1), s)
        else
            add_node!(t, pretty(a, s), s, join_lines = true)
        end
    end
    t
end

# InvisBrackets
function p_invisbrackets(x, s; nonest = false, nospace = false)
    t = PTree(x, nspaces(s))
    nest = !is_iterable(x[2]) && !nonest
    # @info "nest invis" nonest

    for (i, a) in enumerate(x)
        if a.typ === CSTParser.Block
            add_node!(t, p_block(a, s, from_quote = true), s, join_lines = true)
        elseif a.typ === CSTParser.BinaryOpCall
            add_node!(
                t,
                p_binarycall(a, s, nonest = nonest, nospace = nospace),
                s,
                join_lines = true,
            )
        elseif a.typ === CSTParser.InvisBrackets
            add_node!(
                t,
                p_invisbrackets(a, s, nonest = nonest, nospace = nospace),
                s,
                join_lines = true,
            )
        elseif is_opener(a) && nest
            # @info "opening"
            add_node!(t, pretty(a, s), s, join_lines = true)
            add_node!(t, Placeholder(0), s)
        elseif is_closer(a) && nest
            # @info "closing"
            add_node!(t, Placeholder(0), s)
            add_node!(t, pretty(a, s), s, join_lines = true)
        else
            add_node!(t, pretty(a, s), s, join_lines = true)
        end
    end
    t
end

# TupleH
function p_tuple(x, s)
    t = PTree(x, nspaces(s))

    args = get_args(x)
    nest = length(args) > 0 && !(length(args) == 1 && unnestable_arg(args[1]))

    for (i, a) in enumerate(x)
        n = pretty(a, s)
        if is_opener(n) && nest
            add_node!(t, n, s, join_lines = true)
            add_node!(t, Placeholder(0), s)
        elseif is_closer(n) && nest
            add_node!(t, TrailingComma(), s)
            add_node!(t, Placeholder(0), s)
            add_node!(t, n, s, join_lines = true)
        elseif CSTParser.is_comma(a) && i < length(x) && !is_punc(x.args[i+1])
            add_node!(t, n, s, join_lines = true)
            add_node!(t, Placeholder(1), s)
        else
            add_node!(t, n, s, join_lines = true)
        end
    end
    t
end

# Braces
function p_braces(x, s)
    t = PTree(x, nspaces(s))
    nest = length(x) > 2 && !(length(x) == 3 && unnestable_arg(x[2]))

    for (i, a) in enumerate(x)
        n = pretty(a, s)
        if i == 1 && nest
            add_node!(t, n, s, join_lines = true)
            add_node!(t, Placeholder(0), s)
        elseif i == length(x) && nest
            add_node!(t, TrailingComma(), s)
            add_node!(t, Placeholder(0), s)
            add_node!(t, n, s, join_lines = true)
        elseif CSTParser.is_comma(a) && i < length(x) && !is_punc(x.args[i+1])
            add_node!(t, n, s, join_lines = true)
            add_node!(t, Placeholder(1), s)
        else
            add_node!(t, n, s, join_lines = true)
        end
    end
    t
end

# Vect
function p_vect(x, s)
    t = PTree(x, nspaces(s))
    nest = length(x) > 2 && !(length(x) == 3 && unnestable_arg(x[2]))

    for (i, a) in enumerate(x)
        n = pretty(a, s)
        if i == 1 && nest
            add_node!(t, n, s, join_lines = true)
            add_node!(t, Placeholder(0), s)
        elseif i == length(x) && nest
            add_node!(t, TrailingComma(), s)
            add_node!(t, Placeholder(0), s)
            add_node!(t, n, s, join_lines = true)
        elseif CSTParser.is_comma(a) && i < length(x) && !is_punc(x.args[i+1])
            add_node!(t, n, s, join_lines = true)
            add_node!(t, Placeholder(1), s)
        else
            add_node!(t, n, s, join_lines = true)
        end
    end
    t
end


# Parameters
function p_params(x, s)
    t = PTree(x, nspaces(s))
    for (i, a) in enumerate(x)
        n = pretty(a, s)
        if i == length(x) && CSTParser.is_comma(a)
            # do nothing
        elseif CSTParser.is_comma(a) && i < length(x) && !is_punc(x.args[i+1])
            add_node!(t, n, s, join_lines = true)
            add_node!(t, Placeholder(1), s)
        else
            add_node!(t, n, s, join_lines = true)
        end
    end
    t
end

# Import, Export, Using, ImportAll
function p_import(x, s)
    t = PTree(x, nspaces(s))
    add_node!(t, pretty(x[1], s), s)
    add_node!(t, Whitespace(1), s)

    for (i, a) in enumerate(x.args[2:end])
        if CSTParser.is_comma(a) || CSTParser.is_colon(a)
            add_node!(t, pretty(a, s), s, join_lines = true)
            add_node!(t, Placeholder(1), s)
        else
            add_node!(t, pretty(a, s), s, join_lines = true)
        end
    end
    t
end

# Ref
function p_ref(x, s)
    t = PTree(x, nspaces(s))
    nest = length(x) > 5 && !(length(x) == 5 && unnestable_arg(x[3]))
    for (i, a) in enumerate(x)
        if is_closer(a) && nest
            add_node!(t, TrailingComma(), s)
            add_node!(t, Placeholder(0), s)
            add_node!(t, pretty(a, s), s, join_lines = true)
        elseif is_opener(a) && nest
            add_node!(t, pretty(a, s), s, join_lines = true)
            add_node!(t, Placeholder(0), s)
        elseif CSTParser.is_comma(a) && i < length(x) && !is_punc(x.args[i+1])
            add_node!(t, pretty(a, s), s, join_lines = true)
            add_node!(t, Placeholder(1), s)
        elseif a.typ === CSTParser.BinaryOpCall
            add_node!(
                t,
                p_binarycall(a, s, nonest = true, nospace = true),
                s,
                join_lines = true,
            )
        elseif a.typ === CSTParser.InvisBrackets
            add_node!(
                t,
                p_invisbrackets(a, s, nonest = true, nospace = true),
                s,
                join_lines = true,
            )
        else
            add_node!(t, pretty(a, s), s, join_lines = true)
        end
    end
    t
end

# Vcat/TypedVcat
function p_vcat(x, s)
    t = PTree(x, nspaces(s))
    st = x.typ === CSTParser.Vcat ? 1 : 2
    args = get_args(x)
    nest = length(args) > 0 && !(length(args) == 1 && unnestable_arg(args[1]))
    # @info "" nest length(x) st

    for (i, a) in enumerate(x)
        n = pretty(a, s)
        diff_line = t.endline != t.startline
        if is_opener(a) && nest
            add_node!(t, n, s, join_lines = true)
            add_node!(t, Placeholder(0), s)
        elseif !is_closer(a) && i > st
            add_node!(t, n, s, join_lines = true)
            if i != length(x) - 1
                has_semicolon(s.doc, n.startline) && add_node!(t, TrailingSemicolon(), s)
                add_node!(t, Placeholder(1), s)
            # Keep trailing semicolon if there's only one arg
            elseif n_args(x) == 1
                add_node!(t, Semicolon(), s)
                add_node!(t, Placeholder(0), s)
            else
                add_node!(t, Placeholder(0), s)
            end
        else
            # If arguments are on different force nest
            diff_line && (t.force_nest = true)
            add_node!(t, n, s, join_lines = true)
        end
    end
    t
end

# Hcat/TypedHcat
function p_hcat(x, s)
    t = PTree(x, nspaces(s))
    st = x.typ === CSTParser.Hcat ? 1 : 2
    for (i, a) in enumerate(x)
        if i > st && i < length(x) - 1
            add_node!(t, pretty(a, s), s, join_lines = true)
            add_node!(t, Whitespace(1), s)
        else
            add_node!(t, pretty(a, s), s, join_lines = true)
        end
    end
    t
end

# Row
function p_row(x, s)
    t = PTree(x, nspaces(s))
    for (i, a) in enumerate(x)
        if i < length(x)
            add_node!(t, pretty(a, s), s, join_lines = true)
            add_node!(t, Whitespace(1), s)
        else
            add_node!(t, pretty(a, s), s, join_lines = true)
        end
    end
    t
end

# Generator/Filter
function p_gen(x, s)
    t = PTree(x, nspaces(s))
    for (i, a) in enumerate(x)
        if a.typ === CSTParser.KEYWORD
            if a.kind === Tokens.FOR && parent_is(
                a,
                is_iterable,
                ignore_typs = (
                    CSTParser.InvisBrackets,
                    CSTParser.Generator,
                    CSTParser.Flatten,
                    CSTParser.Filter,
                ),
            )
                add_node!(t, Placeholder(1), s)
            else
                add_node!(t, Whitespace(1), s)
            end
            # if a.kind === Tokens.FOR
            #     add_node!(t, Placeholder(1), s)
            # else
            #     add_node!(t, Whitespace(1), s)
            # end

            # add_node!(t, Placeholder(1), s)
            add_node!(t, pretty(a, s), s, join_lines = true)
            add_node!(t, Whitespace(1), s)
            if a.kind === Tokens.FOR
                for j = i+1:length(x)
                    eq_to_in_normalization!(x.args[j], s.always_for_in)
                end
            end
        elseif a.typ === CSTParser.BinaryOpCall
            add_node!(t, p_binarycall(a, s, nonest = true), s, join_lines = true)
        elseif CSTParser.is_comma(a) && i < length(x) && !is_punc(x.args[i+1])
            add_node!(t, pretty(a, s), s, join_lines = true)
            add_node!(t, Whitespace(1), s)
        else
            add_node!(t, pretty(a, s), s, join_lines = true)
        end
    end
    t
end

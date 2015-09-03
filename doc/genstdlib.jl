using .Markdown
using Base.Markdown: MD

cd(dirname(@__FILE__))

isop(func) = ismatch(r"[^\w@!.]|^!$", func)

ident(mod, x) = "$mod.$(isop(x) ? "(:($x))" : x)"

all_docs = ObjectIdDict()

function add_all_docs(it)
    for (k, v) in it
        all_docs[v] = k
    end
end

function add_all_docs(it, k)
    for (_, v) in it
        all_docs[v] = k
    end
end

function add_all_docs_meta(meta)
    for (sym, d) in meta
        if isa(d, Base.Docs.FuncDoc) || isa(d, Base.Docs.TypeDoc)
            add_all_docs(d.meta, sym)
        else
            all_docs[d] = sym
        end
    end
end

mod_added = ObjectIdDict()

function add_all_docs_mod(m::Module)
    mod_added[m] = m
    try
        add_all_docs_meta(Docs.meta(m))
    end
    for name in names(m)
        try
            sub_m = m.(name)
            sub_m in keys(mod_added) || add_all_docs_mod(sub_m)
        end
    end
end

add_all_docs_mod(Base)
# Most of the keywords are not functions and they are easy to check by hand
# add_all_docs(Docs.keywords)

println("Collect $(length(all_docs)) Docs")

function getdoc(mod, x)
    try
        x = unescape_string(x)
        if symbol(x) in keys(Docs.keywords)
            return Any[Docs.keywords[symbol(x)]]
        end
        v = if x[1] != '@'
            eval(parse(ident(mod, x)))
        else
            Docs.Binding(eval(parse(mod)), symbol(x))
        end
        if isa(v, Colon)
            v = Base.colon
        end
        M = Docs.meta(Base)
        if isa(M[v], Base.Docs.FuncDoc) || isa(M[v], Base.Docs.TypeDoc)
            return collect(values(M[v].meta))
        else
            return Any[M[v]]
        end
    catch e
        println(e)
        warn("Mod $mod $x")
    end
    []
end

flat_content(md) = md
flat_content(xs::Vector) = reduce((xs, x) -> vcat(xs,flat_content(x)), [], xs)
flat_content(md::MD) = flat_content(md.content)

flatten(md::MD) = MD(flat_content(md))

isrst(md) =
    length(flatten(md).content) == 1 &&
    isa(flatten(md).content[1], Markdown.Code) &&
    flatten(md).content[1].language == "rst"

function tryrst(md, remove_decl)
    try
        if remove_decl && isa(md.content[1], Markdown.Code) && md.content[1].language == ""
            shift!(md.content)
        end
        return Markdown.rst(md)
    catch e
        warn("Error converting docstring:")
#        display(md)
        println(e)
        return
    end
end

torst(md,remove_decl) = isrst(md) ? flatten(md).content[1].code : tryrst(md, remove_decl)

function split_decl_rst(md, decl)
    if isrst(md)
        rst_text = flatten(md).content[1].code
        ls = split(rst_text, "\n")
        body_start = 1
        if startswith(ls[1], ".. ") && !endswith(ls[1], "::")
            decl = ".. function:: " * replace(ls[1], r"^.. *", "")
            body_start += 1
            while startswith(ls[body_start], "   ")
                decl *= replace(ls[body_start], r"^ *", "\n              ")
                body_start += 1
            end
            while ls[body_start] == ""
                body_start += 1
            end
            return decl, join(ls[body_start:end], "\n")
        end
        return decl, rst_text
    else
        if isa(md.content[1], Markdown.Code) && md.content[1].language == ""
            decl = ".. function:: " * replace(shift!(md.content).code, "\n",
                                              "\n              ")
        end
        return decl, Markdown.rst(md)
    end
end

function translate(file)
    @assert(isfile(file))
    ls = split(readall(file), "\n")[1:end-1]
    doccing = false
    func = nothing
    mod = "Base"
    modidx = -1
    open(file, "w+") do io
        for (i,l) in enumerate(ls)
            if ismatch(r"^\.\. (current)?module::", l)
                mod = match(r"^\.\. (current)?module:: ([\w\.]+)", l).captures[2]
                modidx = i
                println(io, l)
            elseif startswith(l, ".. function::")
                func = match(r"^\.\. function:: (@?[^\(\s\{]+)(.*)", l)
                func == nothing && (warn("bad function $l"); continue)
                funcname = func.captures[1]
                full = funcname * func.captures[2]
                if !('(' in full || '@' in full)
                    ex = parse(full)
                    if isa(ex, Expr)
                        if (ex.head == :(||) || ex.head == :(&&))
                            funcname = string(ex.head)
                        elseif ex.head == :macrocall
                            funcname = string(ex.args[1])
                        end
                    end
                end
                doc = nothing
                for mdoc in getdoc(mod, funcname)
                    trst = tryrst(mdoc, false)
                    trst !== nothing || continue
                    if contains(replace(trst, r"[\n ][\n ]+", " "),
                                " " * replace(full, r"[\n ][\n ]+", " "))
                        if doc != nothing
                            error("duplicate $full $l")
                        end
                        doc = mdoc
                    else
                        #@show trst full
                    end
                end
                if doc == nothing || torst(doc, false) == nothing
                    info("no docs for $full in $mod")
                    println(io, l)
                    doccing = false
                    continue
                end
                delete!(all_docs, doc)
                doccing = true
                decl, body = split_decl_rst(doc, l)
                println(io, decl)
                println(io)
                println(io, "   .. Docstring generated from Julia source\n")
                for l in split(body, "\n")
                    ismatch(r"^\s*$", l) ? println(io) : println(io, "   ", l)
                end
                isrst(doc) && println(io)
            elseif doccing && (ismatch(r"^\s+", l) || ismatch(r"^\s*$", l))
                modidx == i-1 && println(io)
            else
                doccing = false
                println(io, l)
            end
        end
    end
end

for folder in ["stdlib", "manual", "devdocs"]
    println("\nConverting $folder/\n")
    for file in readdir("$folder")
        translate("$folder/$file")
    end
end

missing_count = 0

for (d, v) in all_docs
    isa(v, ObjectIdDict) && continue # No idea what these are
    isa(v, Int) && continue # We don't document `0` as a function
    warn("Missing doc for $v")
    # println(tryrst(d, false))
    # # Generate todo list ;-p
    # println("- [ ] `$v`")
    missing_count += 1
end

if missing_count > 0
    println()
    warn("Missing $missing_count doc strings")
end

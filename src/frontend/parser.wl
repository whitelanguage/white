// frontend/parser.wl
import "tokens.wl" as WhitelangTokens
import "lexer.wl" as WhitelangLexer
import * from "tokens.wl"
import * from "ast.wl"
import * from "arena.wl"
import * from "diagnostics.wl"

struct Parser(
    lexer: WhitelangLexer.Lexer,
    current_tok: Token,
    nesting: Int,
    arena: AstArena
)

struct TypedIdent(
    name_tok: Token,
    type_node: NodeID
)

const MAX_PARSE_NESTING: Int = 256;

func parser_enter(p: Parser, pos: Position) -> Bool {
    if (p.nesting >= MAX_PARSE_NESTING) {
        throw_invalid_syntax(pos, "Syntax nesting exceeds the limit of 256.");
        return false;
    }
    p.nesting += 1;
    return true;
}

func parser_leave(p: Parser) -> Void {
    if (p.nesting > 0) { p.nesting -= 1; }
}

func skip_group(p: Parser, open_type: Int, close_type: Int) -> Void {
    let depth: Int = 0;
    while (p.current_tok.type != TOK_EOF) {
        if (p.current_tok.type == open_type) { depth += 1; }
        else if (p.current_tok.type == close_type) {
            depth -= 1;
            parser_advance(p);
            if (depth == 0) { return; }
            continue;
        }
        parser_advance(p);
    }
}

func nesting_fallback(p: Parser, pos: Position) -> NodeID {
    if (p.current_tok.type == TOK_LPAREN) { skip_group(p, TOK_LPAREN, TOK_RPAREN); }
    else if (p.current_tok.type == TOK_LBRACKET) { skip_group(p, TOK_LBRACKET, TOK_RBRACKET); }
    else if (p.current_tok.type == TOK_LBRACE) { skip_group(p, TOK_LBRACE, TOK_RBRACE); }
    else if (p.current_tok.type != TOK_EOF) { parser_advance(p); }
    let zero_tok: Token = Token(type=TOK_INT, value="0", line=pos.ln, col=pos.col);
    return add_int_node(p.arena, IntNode(type=NODE_INT, tok=zero_tok, pos=pos));
}

func type_nesting_fallback(p: Parser, pos: Position) -> NodeID {
    if (p.current_tok.type != TOK_EOF) { parser_advance(p); }
    let int_tok: Token = Token(type=TOK_T_INT, value="Int", line=pos.ln, col=pos.col);
    return add_var_access_node(p.arena, VarAccessNode(type=NODE_VAR_ACCESS, name_tok=int_tok, pos=pos));
}

func inferred_type(p: Parser, pos: Position) -> NodeID {
    let auto_tok: Token = Token(type=TOK_IDENTIFIER, value="Auto", line=pos.ln, col=pos.col);
    return add_var_access_node(p.arena, VarAccessNode(type=NODE_VAR_ACCESS, name_tok=auto_tok, pos=pos));
}

func is_name_token(token_type: Int) -> Bool {
    return token_type == TOK_IDENTIFIER ||
           token_type == TOK_TYPE;
}

func synchronize(p: Parser) -> Void {
    parser_advance(p);
    while (p.current_tok.type != TOK_EOF) {
        if (p.current_tok.type == TOK_SEMICOLON) {
            parser_advance(p);
            return;
        }
        let type: Int = p.current_tok.type;
        if (type == TOK_FUNC || type == TOK_LET || type == TOK_CONST || type == TOK_IF || type == TOK_WHILE || type == TOK_FOR || type == TOK_RETURN || type == TOK_CLASS || type == TOK_STRUCT || type == TOK_ENUM || type == TOK_ERROR) {
            return;
        }
        parser_advance(p);
    }
}

func parse_annotations(p: Parser) -> Vector(AnnotationNode) {
    let anns: Vector(AnnotationNode) = [];
    while (p.current_tok.type == TOK_AT) {
        let start_pos: Position = Position(idx=0, ln=p.current_tok.line, col=p.current_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
        parser_advance(p); // skip '@'
        
        if (!is_name_token(p.current_tok.type)) {
            throw_invalid_syntax(start_pos, "Expected identifier after '@'.");
        }
        let name: String = p.current_tok.value;
        parser_advance(p); // skip identifier
        
        let args: Vector(ArgNode) = [];
        if (p.current_tok.type == TOK_LPAREN) {
            parser_advance(p); // skip '('
            args = parse_args(p);
            if (p.current_tok.type != TOK_RPAREN) {
                let err_pos: Position = Position(idx=0, ln=p.current_tok.line, col=p.current_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
                throw_invalid_syntax(err_pos, "Expected ')' after annotation arguments.");
            }
            parser_advance(p); // skip ')'
        }
        
        anns.append(AnnotationNode(type=NODE_ANNOTATION, name=name, args=args, pos=start_pos));
    }
    return anns;
}

func parse(p: Parser) -> NodeID {
    let stmts: Vector(NodeID) = [];

    while (p.current_tok.type != TOK_EOF) {
        let stmt: NodeID = NO_NODE;

        let anns: Vector(AnnotationNode) = [];
        if (p.current_tok.type == TOK_AT) {
            anns = parse_annotations(p);
        }

        if (p.current_tok.type == TOK_FUNC) {
            stmt = func_def(p, anns);
        } else if (p.current_tok.type == TOK_STRUCT) {
            stmt = parse_struct_def(p, anns);
        } else if (p.current_tok.type == TOK_CLASS) {
            stmt = parse_class_def(p, anns);
        } else if (p.current_tok.type == TOK_ENUM) {
            stmt = parse_enum_def(p, anns, false);
        } else if (p.current_tok.type == TOK_ERROR) {
            stmt = parse_enum_def(p, anns, true);
        } else if (p.current_tok.type == TOK_INTERFACE) {
            stmt = parse_interface_def(p, anns);
        } else if (p.current_tok.type == TOK_IMPORT) { 
            if (anns.length() > 0) { 
                let err_pos: Position = Position(idx=0, ln=p.current_tok.line, col=p.current_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
                throw_invalid_syntax(err_pos, "Annotations not allowed on imports."); 
            }
            stmt = parse_import(p);
        } else if (p.current_tok.type == TOK_LET || p.current_tok.type == TOK_CONST) {
            stmt = var_decl(p, anns, true);
            if (p.current_tok.type == TOK_SEMICOLON) {
                parser_advance(p);
            } else {
                let err_pos: Position = Position(idx=0, ln=p.current_tok.line, col=p.current_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
                throw_invalid_syntax(err_pos, "Expected ';' after global variable declaration.");
            }
        } else if (p.current_tok.type == TOK_TYPE) {
            if (anns.length() > 0) {
                let err_pos: Position = Position(idx=0, ln=p.current_tok.line, col=p.current_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
                throw_invalid_syntax(err_pos, "Type declarations cannot have annotations.");
            }
            stmt = parse_type_decl(p);
        } else if (p.current_tok.type == TOK_EXTERN) {
            if (anns.length() > 0) { 
                let err_pos: Position = Position(idx=0, ln=p.current_tok.line, col=p.current_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
                throw_invalid_syntax(err_pos, "Annotations not allowed on extern block."); 
            }
            stmt = parse_extern(p);
        } else {
            let err_pos: Position = Position(idx=0, ln=p.current_tok.line, col=p.current_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
            throw_invalid_syntax(err_pos, "Top level code must be function definitions or global variables. Found: " + WhitelangTokens.get_token_name(p.current_tok.type));
            synchronize(p);
            continue;
        }
        if (has_node(stmt)) {
            stmts.append(stmt);
        }
    }
    
    return add_block_node(p.arena, BlockNode(type=NODE_BLOCK, stmts=stmts));
}

func parse_type_decl(p: Parser) -> NodeID {
    let pos: Position = Position(idx=0, ln=p.current_tok.line, col=p.current_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
    parser_advance(p); // skip type

    let name_tok: Token = null;
    let target_type: NodeID = NO_NODE;
    let is_alias: Bool = false;

    if (p.current_tok.type == TOK_IDENTIFIER && peek_type(p) == TOK_ASSIGN) {
        name_tok = p.current_tok;
        parser_advance(p);
        parser_advance(p); // skip =
        target_type = parse_return_type(p);
    } else {
        target_type = parse_return_type(p);
        if (p.current_tok.type != TOK_AS) {
            let err_pos: Position = Position(idx=0, ln=p.current_tok.line, col=p.current_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
            throw_invalid_syntax(err_pos, "Expected 'as' in type alias declaration.");
            return NO_NODE;
        }
        parser_advance(p);
        if (p.current_tok.type != TOK_IDENTIFIER) {
            let err_pos: Position = Position(idx=0, ln=p.current_tok.line, col=p.current_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
            throw_invalid_syntax(err_pos, "Expected alias name after 'as'.");
            return NO_NODE;
        }
        name_tok = p.current_tok;
        is_alias = true;
        parser_advance(p);
    }

    if (p.current_tok.type != TOK_SEMICOLON) {
        let err_pos: Position = Position(idx=0, ln=p.current_tok.line, col=p.current_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
        throw_invalid_syntax(err_pos, "Expected ';' after type declaration.");
    } else {
        parser_advance(p);
    }

    return add_type_decl_node(p.arena, TypeDeclNode(type=NODE_TYPE_DECL, name_tok=name_tok, target_type=target_type, is_alias=is_alias, pos=pos));
}

func parser_advance(p: Parser) -> Void {
    p.current_tok = WhitelangLexer.get_next_token(p.lexer);
}

func is_generic_close(p: Parser, open_type: Int) -> Bool {
    if (open_type == TOK_LT) {
        return p.current_tok.type == TOK_GT || p.current_tok.type == TOK_RSHIFT;
    }
    return p.current_tok.type == TOK_RPAREN;
}

func consume_generic_close(p: Parser, open_type: Int, pos: Position) -> Void {
    if (open_type == TOK_LT) {
        if (p.current_tok.type == TOK_GT) {
            parser_advance(p);
            return;
        }
        if (p.current_tok.type == TOK_RSHIFT) {
            p.current_tok = Token(type=TOK_GT, value=">", line=p.current_tok.line, col=p.current_tok.col + 1);
            return;
        }

        throw_invalid_syntax(pos, "Expected '>' after type arguments.");
        return;
    }
    let close_type: Int = TOK_RPAREN;
    let close_text: String = ")";
    if (p.current_tok.type == close_type) {
        parser_advance(p);
        return;
    }

    throw_invalid_syntax(pos, "Expected '" + close_text + "' after type arguments.");
}

func parse_type_args(p: Parser) -> Vector(NodeID) {
    let pos: Position = Position(idx=0, ln=p.current_tok.line, col=p.current_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
    let open_type: Int = p.current_tok.type;
    let args: Vector(NodeID) = [];
    parser_advance(p);

    if (is_generic_close(p, open_type)) {
        throw_invalid_syntax(pos, "Generic argument lists cannot be empty.");
        consume_generic_close(p, open_type, pos);
        return args;
    }
    while true {
        args.append(parse_return_type(p));
        if (p.current_tok.type != TOK_COMMA) {
            break;
        }
        parser_advance(p);
    }
    consume_generic_close(p, open_type, pos);
    return args;
}

func parse_type_params(p: Parser) -> Vector(GenericParamNode) {
    let pos: Position = Position(idx=0, ln=p.current_tok.line, col=p.current_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
    let open_type: Int = p.current_tok.type;
    let params: Vector(GenericParamNode) = [];
    let names: Dict(String, String) = Dict();
    parser_advance(p);

    if (is_generic_close(p, open_type)) {
        throw_invalid_syntax(pos, "Generic parameter lists cannot be empty.");
        consume_generic_close(p, open_type, pos);
        return params;
    }

    while true {
        if (!is_name_token(p.current_tok.type)) {
            let err_pos: Position = Position(idx=0, ln=p.current_tok.line, col=p.current_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
            throw_invalid_syntax(err_pos, "Expected a type parameter name.");
            break;
        }
        let name_tok: Token = p.current_tok;
        let param_pos: Position = Position(idx=0, ln=name_tok.line, col=name_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
        if (names.contains_key(name_tok.value)) {
            let err_pos: Position = Position(idx=0, ln=p.current_tok.line, col=p.current_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
            throw_name_error(err_pos, "Type parameter '" + p.current_tok.value + "' is already declared.");
        } else {
            names.put(name_tok.value, name_tok.value);
        }
        parser_advance(p);

        let constraints: Vector(NodeID) = [];
        if (p.current_tok.type == TOK_COLON) {
            parser_advance(p);
            constraints.append(parse_return_type(p));
            while (p.current_tok.type == TOK_PLUS) {
                parser_advance(p);
                constraints.append(parse_return_type(p));
            }
        }
        params.append(GenericParamNode(name_tok=name_tok, constraints=constraints, pos=param_pos));
        if (p.current_tok.type != TOK_COMMA) {
            break;
        }
        parser_advance(p);
    }

    consume_generic_close(p, open_type, pos);
    return params;
}

func may_generic_call(p: Parser) -> Bool {
    if (p.current_tok.type != TOK_LT) { return false; }
    let lexer: WhitelangLexer.Lexer = p.lexer;
    let save_idx: Int = lexer.pos.idx;
    let save_ln: Int = lexer.pos.ln;
    let save_col: Int = lexer.pos.col;
    let save_char: Char = lexer.current_char;
    let save_width: Int = lexer.current_width;
    let save_valid: Bool = lexer.current_valid;
    let save_trivia: Bool = lexer.collect_trivia;
    lexer.collect_trivia = false;

    let depth: Int = 1;
    let next: Token = WhitelangLexer.get_next_token(lexer);
    while (next.type != TOK_EOF && depth > 0) {
        if (next.type == TOK_LT) { depth++; }
        else if (next.type == TOK_GT) { depth--; }
        else if (next.type == TOK_RSHIFT) { depth -= 2; }
        if (depth > 0) {
            next = WhitelangLexer.get_next_token(lexer);
        }
    }

    let follows_call: Bool = false;
    if (depth == 0) { follows_call = WhitelangLexer.get_next_token(lexer).type == TOK_LPAREN; }

    lexer.pos.idx = save_idx;
    lexer.pos.ln = save_ln;
    lexer.pos.col = save_col;
    lexer.current_char = save_char;
    lexer.current_width = save_width;
    lexer.current_valid = save_valid;
    lexer.collect_trivia = save_trivia;
    return follows_call;
}

func may_generic_value(p: Parser) -> Bool {
    if (p.current_tok.type != TOK_LT) { return false; }
    let lexer: WhitelangLexer.Lexer = p.lexer;
    let save_idx: Int = lexer.pos.idx;
    let save_ln: Int = lexer.pos.ln;
    let save_col: Int = lexer.pos.col;
    let save_char: Char = lexer.current_char;
    let save_width: Int = lexer.current_width;
    let save_valid: Bool = lexer.current_valid;
    let save_trivia: Bool = lexer.collect_trivia;
    lexer.collect_trivia = false;

    let depth: Int = 1;
    let next: Token = WhitelangLexer.get_next_token(lexer);
    while (next.type != TOK_EOF && depth > 0) {
        if (next.type == TOK_LT) { depth++; }
        else if (next.type == TOK_GT) { depth--; }
        else if (next.type == TOK_RSHIFT) { depth -= 2; }
        if (depth > 0) { next = WhitelangLexer.get_next_token(lexer); }
    }

    let follows_value: Bool = false;
    if (depth == 0) {
        let after: Int = WhitelangLexer.get_next_token(lexer).type;
        follows_value = after == TOK_SEMICOLON || after == TOK_COMMA || after == TOK_RPAREN || after == TOK_RBRACKET;
    }

    lexer.pos.idx = save_idx;
    lexer.pos.ln = save_ln;
    lexer.pos.col = save_col;
    lexer.current_char = save_char;
    lexer.current_width = save_width;
    lexer.current_valid = save_valid;
    lexer.collect_trivia = save_trivia;
    return follows_value;
}

func peek_type(p: Parser) -> Int {
    let l: WhitelangLexer.Lexer = p.lexer;
    
    // save current lexer
    let save_idx: Int = l.pos.idx;
    let save_ln: Int = l.pos.ln;
    let save_col: Int = l.pos.col;
    let save_char: Char = l.current_char;
    let save_width: Int = l.current_width;
    let save_valid: Bool = l.current_valid;
    
    // get next token
    let tok: Token = WhitelangLexer.get_next_token(l);
    let type: Int = tok.type;
    
    // load lexer
    let p_pos: Position = l.pos;
    p_pos.idx = save_idx;
    p_pos.ln  = save_ln;
    p_pos.col = save_col;
    l.current_char = save_char;
    l.current_width = save_width;
    l.current_valid = save_valid;
    
    return type;
}

func parse_decimal_int(p: Parser, tok: Token) -> Int {
    let s: String = tok.value;
    let res: Int = 0;
    let i: Int = 0;
    while (i < s.length()) {
        let code: Char = s[i];
        if (code >= '0' && code <= '9') {
            res = res * 10 + (Int(code) - Int('0'));
        } else {
            let err_pos: Position = Position(idx=0, ln=tok.line, col=tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
            throw_invalid_syntax(err_pos, "Pointer or dereference level must be a pure decimal integer.");
        }
        i += 1;
    }
    return res;
}

func parse_type_base(p: Parser) -> NodeID {
    let pos: Position = Position(idx=0, ln=p.current_tok.line, col=p.current_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
    if (!parser_enter(p, pos)) { return type_nesting_fallback(p, pos); }
    let result: NodeID = parse_type_base_inner(p);
    parser_leave(p);
    return result;
}

func parse_callable_type(p: Parser, tok: Token, is_method: Bool) -> NodeID {
    parser_advance(p);
    let pos: Position = Position(idx=0, ln=tok.line, col=tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);

    if (p.current_tok.type != TOK_LPAREN) {
        return add_var_access_node(p.arena, VarAccessNode(type=NODE_VAR_ACCESS, name_tok=tok, pos=pos));
    }
    parser_advance(p);

    let signature_types: Vector(NodeID) = [];
    let signature_names: Vector(String) = [];
    let variadic_param: Int = 0;
    if (p.current_tok.type != TOK_RPAREN) {
        while (true) {
            let label: String = "";
            if (is_name_token(p.current_tok.type) && peek_type(p) == TOK_COLON) {
                label = p.current_tok.value;
                parser_advance(p);
                parser_advance(p);
            }

            signature_types.append(parse_return_type(p));
            signature_names.append(label);
            if (p.current_tok.type == TOK_ELLIPSIS) {
                if (variadic_param > 0) {
                    let err_pos: Position = Position(idx=0, ln=p.current_tok.line, col=p.current_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
                    throw_invalid_syntax(err_pos, "A callable type can contain only one variadic parameter.");
                }
                if (label.length() > 0) {
                    let err_pos: Position = Position(idx=0, ln=p.current_tok.line, col=p.current_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
                    throw_invalid_syntax(err_pos, "The variadic parameter in a callable type cannot have a label.");
                }
                variadic_param = signature_types.length();
                parser_advance(p);
            }

            if (p.current_tok.type != TOK_COMMA) { break; }
            parser_advance(p);
        }
    }

    let signature_index: Int = 0;
    while (signature_index < signature_types.length()) {
        let label: String = signature_names[signature_index];
        if (variadic_param == 0 && label.length() > 0) {
            let err_pos: Position = Position(idx=0, ln=tok.line, col=tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
            throw_invalid_syntax(err_pos, "Callable labels are only allowed after a variadic parameter.");
        } else if (variadic_param > 0 && signature_index + 1 < variadic_param && label.length() > 0) {
            let err_pos: Position = Position(idx=0, ln=tok.line, col=tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
            throw_invalid_syntax(err_pos, "Parameters before the variadic parameter in a callable type are positional.");
        } else if (variadic_param > 0 && signature_index + 1 > variadic_param && label.length() == 0) {
            let err_pos: Position = Position(idx=0, ln=tok.line, col=tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
            throw_invalid_syntax(err_pos, "Parameters after a variadic parameter in a callable type require labels.");
        }
        signature_index += 1;
    }

    let kind: String = "Function";
    if is_method { kind = "Method"; }
    if (p.current_tok.type != TOK_RPAREN) {
        let err_pos: Position = Position(idx=0, ln=p.current_tok.line, col=p.current_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
        throw_invalid_syntax(err_pos, "Expected ')' after " + kind + " signature.");
    }
    parser_advance(p);

    let return_type: NodeID = NO_NODE;
    let arg_types: Vector(NodeID) = [];
    let arg_names: Vector(String) = [];
    if (p.current_tok.type == TOK_TYPE_ARROW) {
        parser_advance(p);
        return_type = parse_return_type(p);
        let i: Int = 0;
        while (i < signature_types.length()) {
            arg_types.append(signature_types[i]);
            arg_names.append(signature_names[i]);
            i += 1;
        }
    } else {
        let err_pos: Position = Position(idx=0, ln=tok.line, col=tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
        if (signature_types.length() == 0) {
            throw_invalid_syntax(err_pos, kind + "() requires a return type after '->'.");
            return_type = inferred_type(p, pos);
        } else {
            throw_invalid_syntax(err_pos, "Legacy " + kind + " signatures are no longer supported; write '" + kind + "(Args) -> Return'.");
            return_type = signature_types[signature_types.length() - 1];
            let i: Int = 0;
            while (i < signature_types.length() - 1) {
                arg_types.append(signature_types[i]);
                arg_names.append(signature_names[i]);
                i += 1;
            }
        }
    }

    if is_method {
        let method_type: MethodTypeNode = MethodTypeNode(type=NODE_METHOD_TYPE, arg_types=arg_types, arg_names=arg_names, return_type=return_type, variadic_param=variadic_param, pos=pos);
        return add_method_type_node(p.arena, method_type);
    }
    let function_type: FunctionTypeNode = FunctionTypeNode(type=NODE_FUNCTION_TYPE, arg_types=arg_types, arg_names=arg_names, return_type=return_type, variadic_param=variadic_param, pos=pos);
    return add_function_type_node(p.arena, function_type);
}

func parse_type_base_inner(p: Parser) -> NodeID {
    // parse a pointer in type position
    if (p.current_tok.type == TOK_PTR) {
        let start_pos: Position = Position(idx=0, ln=p.current_tok.line, col=p.current_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
        parser_advance(p); // skip ptr

        let level: Int = 1;
        if (p.current_tok.type == TOK_MUL) {
            parser_advance(p);
            if (p.current_tok.type == TOK_INT) {
                level = parse_decimal_int(p, p.current_tok);
                parser_advance(p);
            } else {
                let err_pos: Position = Position(idx=0, ln=p.current_tok.line, col=p.current_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
                throw_invalid_syntax(err_pos, "Expected pointer level.");
            }
        }

        let base: NodeID = parse_type_base(p);
        return add_pointer_type_node(p.arena, PointerTypeNode(type=NODE_PTR_TYPE, base_type=base, level=level, pos=start_pos));
    }

    let tok: Token = p.current_tok;
    let tt: Int = p.current_tok.type;
    let type_node: NodeID = NO_NODE;
    let start_pos: Position = Position(idx=0, ln=tok.line, col=tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);

    if (tt == TOK_T_INT || tt == TOK_T_FLOAT || tt == TOK_T_STRING || tt == TOK_T_BOOL || tt == TOK_T_VOID || tt == TOK_T_CHAR || is_name_token(tt)) {
        if (tok.value == "Function") {
            type_node = parse_callable_type(p, tok, false);
        }
        else if (tok.value == "Method") {
            type_node = parse_callable_type(p, tok, true);
        }
        else if (tok.value == "Vector") {
            parser_advance(p); // skip Vector
            if (p.current_tok.type != TOK_LPAREN) {
                let err_pos: Position = Position(idx=0, ln=p.current_tok.line, col=p.current_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
                throw_invalid_syntax(err_pos, "Expected '(' after Vector.");
            }
            parser_advance(p); // skip (
            
            let elem_type: NodeID = parse_return_type(p);
            
            if (p.current_tok.type != TOK_RPAREN) {
                let err_pos: Position = Position(idx=0, ln=p.current_tok.line, col=p.current_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
                throw_invalid_syntax(err_pos, "Expected ')' after Vector type.");
            }
            parser_advance(p); // skip )
            
            let pos: Position = Position(idx=0, ln=tok.line, col=tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
            type_node = add_vector_type_node(p.arena, VectorTypeNode(type=NODE_VECTOR_TYPE, element_type=elem_type, pos=pos));
        }
        else if (tok.value == "Array") {
            parser_advance(p); // skip Array
            if (p.current_tok.type != TOK_LPAREN) {
                let err_pos: Position = Position(idx=0, ln=p.current_tok.line, col=p.current_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
                throw_invalid_syntax(err_pos, "Expected '(' after Array.");
            }
            parser_advance(p); // skip (
            
            let elem_type: NodeID = parse_return_type(p);
            
            if (p.current_tok.type != TOK_RPAREN) {
                let err_pos: Position = Position(idx=0, ln=p.current_tok.line, col=p.current_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
                throw_invalid_syntax(err_pos, "Expected ')' after Array type.");
            }
            parser_advance(p); // skip )
            
            type_node = add_slice_type_node(p.arena, SliceTypeNode(type=NODE_SLICE_TYPE, element_type=elem_type, pos=start_pos));
        }
        else {
            parser_advance(p);
            let pos: Position = Position(idx=0, ln=tok.line, col=tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
            type_node = add_var_access_node(p.arena, VarAccessNode(type=NODE_VAR_ACCESS, name_tok=tok, pos=pos));

            while (p.current_tok.type == TOK_DOT) {
                parser_advance(p); // skip '.'
                if (!is_name_token(p.current_tok.type)) {
                    let err_pos: Position = Position(idx=0, ln=p.current_tok.line, col=p.current_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
                    throw_invalid_syntax(err_pos, "Expected type name after '.'.");
                }
                let type_name: String = p.current_tok.value;
                parser_advance(p); // skip type_name
                type_node = add_field_access_node(p.arena, FieldAccessNode(type=NODE_FIELD_ACCESS, obj=type_node, field_name=type_name, pos=pos));
            }
        }
        if (p.current_tok.type == TOK_LPAREN) {
            type_node = add_generic_type_node(p.arena, GenericTypeNode(type=NODE_GENERIC_TYPE, base_type=type_node, type_args=parse_type_args(p), pos=start_pos));
        }
        return type_node;
    }
    
    let err_pos: Position = Position(idx=0, ln=tok.line, col=tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
    throw_invalid_syntax(err_pos, "Expected type name.");
    return NO_NODE;
}

func parse_return_type(p: Parser) -> NodeID {
    let type_node: NodeID = parse_type_base(p);
    if (!has_node(type_node)) { return NO_NODE; }

    let start_pos: Position = Position(idx=0, ln=p.current_tok.line, col=p.current_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
    let sizes: Vector(Token) = [];

    while (p.current_tok.type == TOK_LBRACKET) {
        parser_advance(p); // skip '['

        if (p.current_tok.type != TOK_INT) {
            let err_pos: Position = Position(idx=0, ln=p.current_tok.line, col=p.current_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
            throw_invalid_syntax(err_pos, "Expected integer literal for array size.");
        }
        sizes.append(p.current_tok);
        parser_advance(p);
        
        if (p.current_tok.type != TOK_RBRACKET) {
            let err_pos: Position = Position(idx=0, ln=p.current_tok.line, col=p.current_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
            throw_invalid_syntax(err_pos, "Expected ']' after array size.");
        }
        parser_advance(p); // skip ']'
    }

    let s_len: Int = 0;
    if (sizes is !null) { s_len = sizes.length(); }
    let s_i: Int = s_len - 1;
    while (s_i >= 0) {
        let s_tok: Token = sizes[s_i];
        type_node = add_array_type_node(p.arena, ArrayTypeNode(
            type=NODE_ARRAY_TYPE, 
            base_type=type_node, 
            size_tok=s_tok, 
            pos=start_pos
        ));
        s_i -= 1;
    }

    if (p.current_tok.type == TOK_QUESTION) {
        let q_tok: Token = p.current_tok;
        parser_advance(p);
        let pos: Position = Position(idx=0, ln=q_tok.line, col=q_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
        type_node = add_fallible_type_node(p.arena, FallibleTypeNode(
            type=NODE_FALLIBLE_TYPE,
            base_type=type_node,
            pos=pos
        ));
    }

    return type_node;
}

func parse_typed_name(p: Parser, allow_inference: Bool) -> TypedIdent {
    // parse a declared name and its optional pointer prefix
    let is_ptr: Bool = false;
    let level: Int = 0;
    let start_pos: Position = Position(idx=0, ln=p.current_tok.line, col=p.current_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);

    if (p.current_tok.type == TOK_PTR) {
        is_ptr = true;
        level = 1;
        parser_advance(p); // skip ptr

        if (p.current_tok.type == TOK_MUL) {
            parser_advance(p);
            if (p.current_tok.type == TOK_INT) {
                level = parse_decimal_int(p, p.current_tok);
                parser_advance(p);
            } else {
                let err_pos: Position = Position(idx=0, ln=p.current_tok.line, col=p.current_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
                throw_invalid_syntax(err_pos, "Expected pointer level.");
            }
        }
    }

    if (!is_name_token(p.current_tok.type) && p.current_tok.type != TOK_SELF && p.current_tok.type != TOK_THIS) {
        let err_pos: Position = Position(idx=0, ln=p.current_tok.line, col=p.current_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
        throw_invalid_syntax(err_pos, "Expected identifier.");
    }
    let name_tok: Token = p.current_tok;
    parser_advance(p);

    let separator: Int = p.current_tok.type;
    let type_node: NodeID = NO_NODE;
    if (separator == TOK_COLON) {
        parser_advance(p);
        let type_pos: Position = Position(idx=0, ln=p.current_tok.line, col=p.current_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
        type_node = parse_return_type(p);
        if (!is_ptr && has_node(type_node)) {
            let declared_type: Int = node_tag(type_node);
            if (declared_type == NODE_PTR_TYPE) {
                throw_invalid_syntax(type_pos, "Place 'ptr' before the declared name; write 'ptr " + name_tok.value + ": Type'.");
            }
        }
    } else if (separator == TOK_TYPE_ARROW) {
        let err_pos: Position = Position(idx=0, ln=p.current_tok.line, col=p.current_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
        if is_ptr {
            throw_invalid_syntax(err_pos, "Type annotations use ':'; write 'ptr " + name_tok.value + ": Type'.");
        } else {
            throw_invalid_syntax(err_pos, "Type annotations use ':'; write '" + name_tok.value + ": Type'.");
        }
        parser_advance(p);
        type_node = parse_return_type(p);
    } else if (allow_inference && !is_ptr && separator == TOK_ASSIGN) {
        type_node = inferred_type(p, start_pos);
    } else {
        let err_pos: Position = Position(idx=0, ln=p.current_tok.line, col=p.current_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
        if allow_inference {
            throw_invalid_syntax(err_pos, "Expected a type annotation or initializer after '" + name_tok.value + "'.");
        } else {
            throw_invalid_syntax(err_pos, "Expected ':' after '" + name_tok.value + "'.");
        }
        type_node = inferred_type(p, start_pos);
    }

    if is_ptr {
        type_node = add_pointer_type_node(p.arena, PointerTypeNode(type=NODE_PTR_TYPE, base_type=type_node, level=level, pos=start_pos));
    }

    return TypedIdent(name_tok=name_tok, type_node=type_node);
}

func atom(p: Parser) -> NodeID {
    let tok: Token = p.current_tok;

    // Integer literals
    if (tok.type == TOK_INT) {
        parser_advance(p);
        let pos: Position = Position(idx=0, ln=tok.line, col=tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
        return add_int_node(p.arena, IntNode(type=NODE_INT, tok=tok, pos=pos));
    }

    // Floating-point literals
    if (tok.type == TOK_FLOAT) {
        parser_advance(p);
        let pos: Position = Position(idx=0, ln=tok.line, col=tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
        return add_float_node(p.arena, FloatNode(type=NODE_FLOAT, tok=tok, pos=pos));
    }

    // Boolean
    if (tok.type == TOK_TRUE) { 
        parser_advance(p);
        let pos: Position = Position(idx=0, ln=tok.line, col=tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
        return add_bool_node(p.arena, BooleanNode(type=NODE_BOOL, tok=tok, value=1, pos=pos)); 
    }
    if (tok.type == TOK_FALSE) { 
        parser_advance(p);
        let pos: Position = Position(idx=0, ln=tok.line, col=tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
        return add_bool_node(p.arena, BooleanNode(type=NODE_BOOL, tok=tok, value=0, pos=pos)); 
    }

    // Char
    if (tok.type == TOK_CHAR_LIT) {
        parser_advance(p);
        let pos: Position = Position(idx=0, ln=tok.line, col=tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
        return add_char_node(p.arena, CharNode(type=NODE_CHAR, tok=tok, pos=pos));
    }

    // String
    if (tok.type == TOK_STR_LIT) {
        parser_advance(p);
        let pos: Position = Position(idx=0, ln=tok.line, col=tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
        return add_string_node(p.arena, StringNode(type=NODE_STRING, tok=tok, pos=pos));
    }

    // nullptr
    if (tok.type == TOK_NULLPTR) {
        parser_advance(p);
        let pos: Position = Position(idx=0, ln=tok.line, col=tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
        return add_nullptr_node(p.arena, NullPtrNode(type=NODE_NULLPTR, pos=pos));
    }

    if (tok.type == TOK_NULL) {
        parser_advance(p);
        let pos: Position = Position(idx=0, ln=tok.line, col=tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
        return add_null_node(p.arena, NullNode(type=NODE_NULL, pos=pos));
    }
    
    // Variable access or Built-in Type Cast Call
    let tt: Int = tok.type;
    if (is_name_token(tt) ||
        tt == TOK_T_INT || tt == TOK_T_FLOAT || tt == TOK_T_STRING || 
        tt == TOK_T_BOOL || tt == TOK_T_CHAR || tt == TOK_T_VOID) {

        parser_advance(p);
        let pos: Position = Position(idx=0, ln=tok.line, col=tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
        if ((tok.value == "size_of" || tok.value == "align_of") && p.current_tok.type == TOK_LPAREN) {
            parser_advance(p);
            if (p.current_tok.type == TOK_RPAREN) {
                throw_type_error(pos, "Expected 1 arguments, got 0");
                parser_advance(p);
                let fallback_tok: Token = Token(type=TOK_T_INT, value="Int", line=tok.line, col=tok.col);
                let fallback_type: NodeID = add_var_access_node(p.arena, VarAccessNode(type=NODE_VAR_ACCESS, name_tok=fallback_tok, pos=pos));
                return add_type_layout_node(p.arena, TypeLayoutNode(type=NODE_TYPE_LAYOUT, type_node=fallback_type, is_align=tok.value == "align_of", pos=pos));
            }
            let type_node: NodeID = parse_return_type(p);
            let arg_count: Int = 1;
            let count_pos: Position = pos;
            while (p.current_tok.type == TOK_COMMA) {
                if (arg_count == 1) { count_pos = Position(idx=0, ln=p.current_tok.line, col=p.current_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn); }
                parser_advance(p);
                parse_return_type(p);
                arg_count += 1;
            }
            if (arg_count != 1) { throw_type_error(count_pos, "Expected 1 arguments, got " + arg_count); }
            if (p.current_tok.type != TOK_RPAREN) {
                let err_pos: Position = Position(idx=0, ln=p.current_tok.line, col=p.current_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
                throw_invalid_syntax(err_pos, "Expected ')' after type in '" + tok.value + "'.");
            } else {
                parser_advance(p);
            }
            return add_type_layout_node(p.arena, TypeLayoutNode(type=NODE_TYPE_LAYOUT, type_node=type_node, is_align=tok.value == "align_of", pos=pos));
        }
        return add_var_access_node(p.arena, VarAccessNode(type=NODE_VAR_ACCESS, name_tok=tok, pos=pos));
    }

    if (tok.type == TOK_THIS) {
        parser_advance(p);
        let pos: Position = Position(idx=0, ln=tok.line, col=tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
        let this_tok: Token = Token(type=TOK_IDENTIFIER, value="this", line=tok.line, col=tok.col);
        return add_var_access_node(p.arena, VarAccessNode(type=NODE_VAR_ACCESS, name_tok=this_tok, pos=pos));
    }

    if (tok.type == TOK_SELF) {
        parser_advance(p);
        let pos: Position = Position(idx=0, ln=tok.line, col=tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
        let self_tok: Token = Token(type=TOK_IDENTIFIER, value="self", line=tok.line, col=tok.col);
        return add_var_access_node(p.arena, VarAccessNode(type=NODE_VAR_ACCESS, name_tok=self_tok, pos=pos));
    }

    if (tok.type == TOK_SUPER) {
        parser_advance(p);
        let pos: Position = Position(idx=0, ln=tok.line, col=tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
        return add_super_node(p.arena, SuperNode(type=NODE_SUPER, pos=pos));
    }

    // Parenthesized expressions
    if (tok.type == TOK_LPAREN) {
        parser_advance(p);
        let node: NodeID = expression(p);
        
        if (p.current_tok.type != TOK_RPAREN) {
            let err_pos: Position = Position(idx=0, ln=p.current_tok.line, col=p.current_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
            throw_invalid_syntax(err_pos, "Expected ')'. ");
        }
        parser_advance(p);
        return node;
    }

    if (tok.type == TOK_LBRACE) {
        parser_advance(p); // skip '{'
        let pos: Position = Position(idx=0, ln=tok.line, col=tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
        
        let pairs: Vector(MapPairNode) = [];

        if (p.current_tok.type != TOK_RBRACE) {
            while (true) {
                let key_node: NodeID = expression(p);
                
                if (p.current_tok.type != TOK_COLON) {
                    let err_pos: Position = Position(idx=0, ln=p.current_tok.line, col=p.current_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
                    throw_invalid_syntax(err_pos, "Expected ':' after dictionary key.");
                }
                parser_advance(p); // skip ':'
                
                let val_node: NodeID = expression(p);
                
                pairs.append(MapPairNode(key=key_node, value=val_node));
                
                if (p.current_tok.type == TOK_COMMA) {
                    parser_advance(p); // skip ','
                    if (p.current_tok.type == TOK_RBRACE) {
                        break;
                    }
                } else {
                    break;
                }
            }
        }
        
        if (p.current_tok.type != TOK_RBRACE) {
            let err_pos: Position = Position(idx=0, ln=p.current_tok.line, col=p.current_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
            throw_invalid_syntax(err_pos, "Expected '}' to close dictionary literal.");
        }
        parser_advance(p); // skip '}'
        
        return add_map_lit_node(p.arena, MapLitNode(type=NODE_MAP_LIT, pairs=pairs, pos=pos));
    }

    if (tok.type == TOK_LBRACKET) {
        parser_advance(p); // skip [
        let pos: Position = Position(idx=0, ln=tok.line, col=tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
        
        let elements: Vector(ArgNode) = [];
        let count: Int = 0;
        
        if (p.current_tok.type != TOK_RBRACKET) {
            while (true) {
                let val: NodeID = expression(p);
                elements.append(ArgNode(val=val, name=null));
                count += 1;
                
                if (p.current_tok.type == TOK_COMMA) {
                    parser_advance(p);
                } else {
                    break;
                }
            }
        }
        
        if (p.current_tok.type != TOK_RBRACKET) {
            let err_pos: Position = Position(idx=0, ln=p.current_tok.line, col=p.current_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
            throw_invalid_syntax(err_pos, "Expected ']' after vector elements.");
        }
        parser_advance(p); // skip ]
        
        return add_vector_lit_node(p.arena, VectorLitNode(type=NODE_VECTOR_LIT, elements=elements, count=count, pos=pos));
    }

    let err_pos: Position = Position(idx=0, ln=tok.line, col=tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
    throw_invalid_syntax(err_pos, "Unexpected token '" + WhitelangTokens.get_token_name(tok.type) + "'");
    if (p.current_tok.type != TOK_EOF) { parser_advance(p); }
    let zero_tok: Token = Token(type=TOK_INT, value="0", line=tok.line, col=tok.col);
    return add_int_node(p.arena, IntNode(type=NODE_INT, tok=zero_tok, pos=err_pos));
}

func parse_args(p: Parser) -> Vector(ArgNode) {
    if (p.current_tok.type == TOK_RPAREN) { return null; }

    let args: Vector(ArgNode) = [];
    
    while (p.current_tok.type != TOK_RPAREN && p.current_tok.type != TOK_EOF) {
        let arg_name: String = null;
        if (is_name_token(p.current_tok.type) && peek_type(p) == TOK_ASSIGN) {
            arg_name = p.current_tok.value;
            parser_advance(p);
            parser_advance(p);
        }
        
        let val: NodeID = expression(p);
        let is_spread: Bool = false;
        if (p.current_tok.type == TOK_ELLIPSIS) {
            if (arg_name is !null) {
                let err_pos: Position = Position(idx=0, ln=p.current_tok.line, col=p.current_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
                throw_invalid_syntax(err_pos, "A spread argument cannot be named.");
            }
            is_spread = true;
            parser_advance(p);
        }
        args.append(ArgNode(val=val, name=arg_name, is_spread=is_spread));

        if (p.current_tok.type == TOK_COMMA) { parser_advance(p); }
        else { break; }
    }
    return args;
}

func postfix_expr(p: Parser) -> NodeID {
    let node: NodeID = atom(p);

    while (p.current_tok.type == TOK_INC || p.current_tok.type == TOK_DEC || p.current_tok.type == TOK_LPAREN ||
           p.current_tok.type == TOK_DOT || p.current_tok.type == TOK_LBRACKET || p.current_tok.type == TOK_QUESTION ||
           (p.current_tok.type == TOK_LT && (may_generic_call(p) || may_generic_value(p)))) {
        // ++ / --
        if (p.current_tok.type == TOK_INC || p.current_tok.type == TOK_DEC) {
            let op_tok: Token = p.current_tok;
            parser_advance(p);
            let pos: Position = Position(idx=0, ln=op_tok.line, col=op_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
            node = add_postfix_node(p.arena, PostfixOpNode(type=NODE_POSTFIX, node=node, op_tok=op_tok, pos=pos));
        }

        else if (p.current_tok.type == TOK_LT && (may_generic_call(p) || may_generic_value(p))) {
            let pos: Position = Position(idx=0, ln=p.current_tok.line, col=p.current_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
            node = add_generic_type_node(p.arena, GenericTypeNode(type=NODE_GENERIC_TYPE, base_type=node, type_args=parse_type_args(p), pos=pos));
        }

        else if (p.current_tok.type == TOK_QUESTION) {
            let op_tok: Token = p.current_tok;
            parser_advance(p);
            let pos: Position = Position(idx=0, ln=op_tok.line, col=op_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
            let target_base: Int = node_tag(node);
            if (target_base == NODE_CALL) {
                let target_call: CallNode = get_call_node(p.arena, node);
                target_call.preserve_fallible = true;
            }
            node = add_try_unwrap_node(p.arena, TryUnwrapNode(type=NODE_TRY_UNWRAP, expr=node, pos=pos));
        }

        else if (p.current_tok.type == TOK_LPAREN) {
            let paren_tok: Token = p.current_tok; // '('
            parser_advance(p); // skip '('
            
            let args: Vector(ArgNode) = parse_args(p);
            
            if (p.current_tok.type != TOK_RPAREN) {
                let err_pos: Position = Position(idx=0, ln=p.current_tok.line, col=p.current_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
                throw_invalid_syntax(err_pos, "Expected ')' after arguments. ");
            }
            parser_advance(p); // skip ')'

            let pos: Position = Position(idx=0, ln=paren_tok.line, col=paren_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);

            let type_args: Vector(NodeID) = null;
            let call_base: Int = node_tag(node);
            if (call_base == NODE_GENERIC_TYPE) {
                let generic: GenericTypeNode = get_generic_type_node(p.arena, node);
                type_args = generic.type_args;
            }

            node = add_call_node(p.arena, CallNode(type=NODE_CALL, callee=node, args=args, type_args=type_args, pos=pos, preserve_fallible=false));
        }

        else if (p.current_tok.type == TOK_DOT) {
            parser_advance(p); // skip .
            if (!is_name_token(p.current_tok.type)) {
                let err_pos: Position = Position(idx=0, ln=p.current_tok.line, col=p.current_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
                throw_invalid_syntax(err_pos, "Expected field name after '.'.");
            }
            let field_name: String = p.current_tok.value;
            let pos: Position = Position(idx=0, ln=p.current_tok.line, col=p.current_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
            parser_advance(p);
    
            node = add_field_access_node(p.arena, FieldAccessNode(type=NODE_FIELD_ACCESS, obj=node, field_name=field_name, pos=pos));
        }

        else if (p.current_tok.type == TOK_LBRACKET) {
            let bracket_tok: Token = p.current_tok;
            parser_advance(p); // skip [

            if (p.current_tok.type == TOK_COLON) {
                parser_advance(p); // skip ':'
                if (p.current_tok.type != TOK_RBRACKET) {
                    let err_pos: Position = Position(idx=0, ln=p.current_tok.line, col=p.current_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
                    throw_invalid_syntax(err_pos, "Expected ']' after ':' in complete slice. Partial slice bounds are not supported. ");
                    expression(p);
                }
                if (p.current_tok.type == TOK_RBRACKET) { parser_advance(p); }
                let pos: Position = Position(idx=0, ln=bracket_tok.line, col=bracket_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
                node = add_slice_access_node(p.arena, SliceAccessNode(type=NODE_SLICE_ACCESS, target=node, start_idx=NO_NODE, end_idx=NO_NODE, pos=pos));
            }
            else {
                let first_idx: NodeID = expression(p);
                if (p.current_tok.type == TOK_COLON) {
                    parser_advance(p); // skip ':'
                    let second_idx: NodeID = expression(p);

                    if (p.current_tok.type != TOK_RBRACKET) {
                        let err_pos: Position = Position(idx=0, ln=p.current_tok.line, col=p.current_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
                        throw_invalid_syntax(err_pos, "Expected ']' after slice end index.");
                    }
                    parser_advance(p); // skip ']'

                    let pos: Position = Position(idx=0, ln=bracket_tok.line, col=bracket_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
                    node = add_slice_access_node(p.arena, SliceAccessNode(type=NODE_SLICE_ACCESS, target=node, start_idx=first_idx, end_idx=second_idx, pos=pos));
                }
                else {
                    if (p.current_tok.type != TOK_RBRACKET) {
                        let err_pos: Position = Position(idx=0, ln=p.current_tok.line, col=p.current_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
                        throw_invalid_syntax(err_pos, "Expected ']' after index.");
                    }
                    parser_advance(p); // skip ']'

                    let pos: Position = Position(idx=0, ln=bracket_tok.line, col=bracket_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
                    node = add_index_access_node(p.arena, IndexAccessNode(type=NODE_INDEX_ACCESS, target=node, index_node=first_idx, pos=pos));
                }
            }
        }
    }
    return node;
}

func unary_expr(p: Parser) -> NodeID {
    let tok: Token = p.current_tok;

    // ref x
    if (tok.type == TOK_REF) {
        parser_advance(p);
        let pos: Position = Position(idx=0, ln=tok.line, col=tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
        if (!parser_enter(p, pos)) { return nesting_fallback(p, pos); }
        let node: NodeID = unary_expr(p);
        parser_leave(p);
        return add_ref_node(p.arena, RefNode(type=NODE_REF, node=node, pos=pos));
    }
    
    // deref x or deref*N x
    if (tok.type == TOK_DEREF) {
        parser_advance(p);
        let level: Int = 1;
        if (p.current_tok.type == TOK_MUL) {
            parser_advance(p);
            if (p.current_tok.type == TOK_INT) {
                level = parse_decimal_int(p, p.current_tok);
                parser_advance(p);
            } else {
                let err_pos: Position = Position(idx=0, ln=p.current_tok.line, col=p.current_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
                throw_invalid_syntax(err_pos, "Expected dereference level.");
            }
        }
        let pos: Position = Position(idx=0, ln=tok.line, col=tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
        if (!parser_enter(p, pos)) { return nesting_fallback(p, pos); }
        let node: NodeID = unary_expr(p);
        parser_leave(p);
        return add_deref_node(p.arena, DerefNode(type=NODE_DEREF, node=node, level=level, pos=pos));
    }
    
    // -5, +3.14, !b, ~c
    if (tok.type == TOK_PLUS || tok.type == TOK_SUB || tok.type == TOK_NOT || tok.type == TOK_BIT_NOT) {
        parser_advance(p);
        let pos: Position = Position(idx=0, ln=tok.line, col=tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
        if (!parser_enter(p, pos)) { return nesting_fallback(p, pos); }
        let node: NodeID = unary_expr(p); // recursive
        parser_leave(p);
        return add_unary_node(p.arena, UnaryOpNode(type=NODE_UNARYOP, op_tok=tok, node=node, pos=pos));
    }
    
    return power(p);
}

func power(p: Parser) -> NodeID {
    let left: NodeID = postfix_expr(p);

    if (p.current_tok.type == TOK_POW) {
        let op_tok: Token = p.current_tok;
        parser_advance(p);
        let pos: Position = Position(idx=0, ln=op_tok.line, col=op_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
        if (!parser_enter(p, pos)) { return nesting_fallback(p, pos); }
        let right: NodeID = factor(p);
        parser_leave(p);
        return add_binop_node(p.arena, BinOpNode(type=NODE_BINOP, left=left, op_tok=op_tok, right=right, pos=pos));
    }
    
    return left;
}

func shift_expr(p: Parser) -> NodeID {
    let left: NodeID = arith_expr(p);
    while (p.current_tok.type == TOK_LSHIFT || p.current_tok.type == TOK_RSHIFT) {
        let op_tok: Token = p.current_tok;
        parser_advance(p);
        let right: NodeID = arith_expr(p);
        let pos: Position = Position(idx=0, ln=op_tok.line, col=op_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
        left = add_binop_node(p.arena, BinOpNode(type=NODE_BINOP, left=left, op_tok=op_tok, right=right, pos=pos));
    }
    return left;
}

func comp_expr(p: Parser) -> NodeID {
    let left: NodeID = shift_expr(p);

    while (p.current_tok.type == TOK_EE  || p.current_tok.type == TOK_NE  || 
           p.current_tok.type == TOK_LT  || p.current_tok.type == TOK_GT  ||
           p.current_tok.type == TOK_LTE || p.current_tok.type == TOK_GTE ||
           p.current_tok.type == TOK_IS) {
        let op_tok: Token = p.current_tok;
        let node_type: Int = NODE_BINOP;

        if (op_tok.type == TOK_IS) {
            parser_advance(p); // skip 'is'
            if (p.current_tok.type == TOK_NOT) {
                let not_tok: Token = p.current_tok;
                parser_advance(p); // skip '!'
                op_tok = Token(type=TOK_IS, value="is !", line=op_tok.line, col=op_tok.col);
                node_type = NODE_IS_NOT;
            } else {
                node_type = NODE_IS;
            }
            
            let right: NodeID = shift_expr(p);
            let pos: Position = Position(idx=0, ln=op_tok.line, col=op_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
            left = add_binop_node(p.arena, BinOpNode(type=node_type, left=left, op_tok=op_tok, right=right, pos=pos));
            
            // continue loop
        } else {
            parser_advance(p);
            let right: NodeID = shift_expr(p);
            let pos: Position = Position(idx=0, ln=op_tok.line, col=op_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
            left = add_binop_node(p.arena, BinOpNode(type=NODE_BINOP, left=left, op_tok=op_tok, right=right, pos=pos));
        }
    }
    return left;
}

func bitwise_and(p: Parser) -> NodeID {
    let left: NodeID = comp_expr(p);
    while (p.current_tok.type == TOK_BIT_AND) {
        let op_tok: Token = p.current_tok;
        parser_advance(p);
        let right: NodeID = comp_expr(p);
        let pos: Position = Position(idx=0, ln=op_tok.line, col=op_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
        left = add_binop_node(p.arena, BinOpNode(type=NODE_BINOP, left=left, op_tok=op_tok, right=right, pos=pos));
    }
    return left;
}

func bitwise_xor(p: Parser) -> NodeID {
    let left: NodeID = bitwise_and(p);
    while (p.current_tok.type == TOK_BIT_XOR) {
        let op_tok: Token = p.current_tok;
        parser_advance(p);
        let right: NodeID = bitwise_and(p);
        let pos: Position = Position(idx=0, ln=op_tok.line, col=op_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
        left = add_binop_node(p.arena, BinOpNode(type=NODE_BINOP, left=left, op_tok=op_tok, right=right, pos=pos));
    }
    return left;
}

func bitwise_or(p: Parser) -> NodeID {
    let left: NodeID = bitwise_xor(p);
    while (p.current_tok.type == TOK_BIT_OR) {
        let op_tok: Token = p.current_tok;
        parser_advance(p);
        let right: NodeID = bitwise_xor(p);
        let pos: Position = Position(idx=0, ln=op_tok.line, col=op_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
        left = add_binop_node(p.arena, BinOpNode(type=NODE_BINOP, left=left, op_tok=op_tok, right=right, pos=pos));
    }
    return left;
}

func logic_and(p: Parser) -> NodeID {
    let left: NodeID = bitwise_or(p);
    while (p.current_tok.type == TOK_AND) {
        let op_tok: Token = p.current_tok;
        parser_advance(p);
        let right: NodeID = bitwise_or(p);
        let pos: Position = Position(idx=0, ln=op_tok.line, col=op_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
        left = add_binop_node(p.arena, BinOpNode(type=NODE_BINOP, left=left, op_tok=op_tok, right=right, pos=pos));
    }
    return left;
}

func logic_or(p: Parser) -> NodeID {
    let left: NodeID = logic_and(p);

    while (p.current_tok.type == TOK_OR) {
        let op_tok: Token = p.current_tok;
        parser_advance(p);
        let right: NodeID = logic_and(p);
        let pos: Position = Position(idx=0, ln=op_tok.line, col=op_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
        left = add_binop_node(p.arena, BinOpNode(type=NODE_BINOP, left=left, op_tok=op_tok, right=right, pos=pos));
    }
    return left;
}

func assignment(p: Parser) -> NodeID {
    let left: NodeID = logic_or(p);

    // =
    if (p.current_tok.type == TOK_ASSIGN) {
        let op_tok: Token = p.current_tok;
        parser_advance(p); // skip '='
        let right: NodeID = assignment(p);
        
        let base: Int = node_tag(left);
        if (base == NODE_VAR_ACCESS) {
            let v_node: VarAccessNode = get_var_access_node(p.arena, left);
            let pos: Position = Position(idx=0, ln=op_tok.line, col=op_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
            return add_var_assign_node(p.arena, VarAssignNode(type=NODE_VAR_ASSIGN, name_tok=v_node.name_tok, value=right, pos=pos));
        } else if (base == NODE_FIELD_ACCESS) {
            let f_node: FieldAccessNode = get_field_access_node(p.arena, left);
            let pos: Position = Position(idx=0, ln=op_tok.line, col=op_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
            return add_field_assign_node(p.arena, FieldAssignNode(type=NODE_FIELD_ASSIGN, obj=f_node.obj, field_name=f_node.field_name, value=right, pos=pos));
        } else if (base == NODE_DEREF) {
            let pos: Position = Position(idx=0, ln=op_tok.line, col=op_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
            return add_ptr_assign_node(p.arena, PtrAssignNode(type=NODE_PTR_ASSIGN, pointer=left, value=right, pos=pos));
        } else if (base == NODE_INDEX_ACCESS) {
            let idx_node: IndexAccessNode = get_index_access_node(p.arena, left);
            let pos: Position = Position(idx=0, ln=op_tok.line, col=op_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
            return add_index_assign_node(p.arena, IndexAssignNode(type=NODE_INDEX_ASSIGN, target=idx_node.target, index_node=idx_node.index_node, value=right, pos=pos));
        } else {
            let err_pos: Position = Position(idx=0, ln=op_tok.line, col=op_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
            throw_invalid_syntax(err_pos, "Invalid assignment target.");
        }
    }

    let op_type: Int = p.current_tok.type;
    if (op_type == TOK_PLUS_ASSIGN || op_type == TOK_SUB_ASSIGN || 
        op_type == TOK_MUL_ASSIGN || op_type == TOK_DIV_ASSIGN || 
        op_type == TOK_MOD_ASSIGN || op_type == TOK_POW_ASSIGN ||
        op_type == TOK_BIT_AND_ASSIGN || op_type == TOK_BIT_OR_ASSIGN || 
        op_type == TOK_BIT_XOR_ASSIGN || op_type == TOK_LSHIFT_ASSIGN || op_type == TOK_RSHIFT_ASSIGN) {
        
        let op_tok: Token = p.current_tok;
        parser_advance(p);
        let right: NodeID = assignment(p);

        let bin_op_type: Int = 0;
        if (op_type == TOK_PLUS_ASSIGN) { bin_op_type = TOK_PLUS; }
        if (op_type == TOK_SUB_ASSIGN)  { bin_op_type = TOK_SUB; }
        if (op_type == TOK_MUL_ASSIGN)  { bin_op_type = TOK_MUL; }
        if (op_type == TOK_DIV_ASSIGN)  { bin_op_type = TOK_DIV; }
        if (op_type == TOK_MOD_ASSIGN)  { bin_op_type = TOK_MOD; }
        if (op_type == TOK_POW_ASSIGN)  { bin_op_type = TOK_POW; }
        if (op_type == TOK_BIT_AND_ASSIGN) { bin_op_type = TOK_BIT_AND; }
        if (op_type == TOK_BIT_OR_ASSIGN)  { bin_op_type = TOK_BIT_OR; }
        if (op_type == TOK_BIT_XOR_ASSIGN) { bin_op_type = TOK_BIT_XOR; }
        if (op_type == TOK_LSHIFT_ASSIGN)  { bin_op_type = TOK_LSHIFT; }
        if (op_type == TOK_RSHIFT_ASSIGN)  { bin_op_type = TOK_RSHIFT; }
        
        let bin_tok: Token = Token(type=bin_op_type, value="compound_op", line=op_tok.line, col=op_tok.col);
        let pos: Position = Position(idx=0, ln=op_tok.line, col=op_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);

        let bin_node: NodeID = add_binop_node(p.arena, BinOpNode(type=NODE_BINOP, left=left, op_tok=bin_tok, right=right, pos=pos));

        let base: Int = node_tag(left);
        
        // a += 1
        if (base == NODE_VAR_ACCESS) {
            let v_node: VarAccessNode = get_var_access_node(p.arena, left);
            return add_var_assign_node(p.arena, VarAssignNode(type=NODE_VAR_ASSIGN, name_tok=v_node.name_tok, value=bin_node, pos=pos));
        } 
        // s.x += 1
        else if (base == NODE_FIELD_ACCESS) {
            let f_node: FieldAccessNode = get_field_access_node(p.arena, left);
            return add_field_assign_node(p.arena, FieldAssignNode(type=NODE_FIELD_ASSIGN, obj=f_node.obj, field_name=f_node.field_name, value=bin_node, pos=pos));
        }
        // (deref p) += 1
        else if (base == NODE_DEREF) {
            return add_ptr_assign_node(p.arena, PtrAssignNode(type=NODE_PTR_ASSIGN, pointer=left, value=bin_node, pos=pos));
        }

        else {
            let err_pos: Position = Position(idx=0, ln=op_tok.line, col=op_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
            throw_invalid_syntax(err_pos, "Invalid compound assignment target. Only variables, fields, and pointers are supported.");
        }
    }

    return left;
}

func factor(p: Parser) -> NodeID {
    return unary_expr(p);
}

func expression(p: Parser) -> NodeID {
// precedence lives in the expression call chain, assignment is the lowest level

    let pos: Position = Position(idx=0, ln=p.current_tok.line, col=p.current_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
    if (!parser_enter(p, pos)) { return nesting_fallback(p, pos); }
    let result: NodeID = assignment(p);
    parser_leave(p);
    return result;
}

func term(p: Parser) -> NodeID {
    let left: NodeID = factor(p);

    // left-associative
    while (p.current_tok.type == TOK_MUL || p.current_tok.type == TOK_DIV || p.current_tok.type == TOK_MOD) {
        let op_tok: Token = p.current_tok;
        parser_advance(p);
        let right: NodeID = factor(p);
        let pos: Position = Position(idx=0, ln=op_tok.line, col=op_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
        left = add_binop_node(p.arena, BinOpNode(type=NODE_BINOP, left=left, op_tok=op_tok, right=right, pos=pos));
    }
    
    return left;
}

func arith_expr(p: Parser) -> NodeID {
    let left: NodeID = term(p);

    // left-associative
    while (p.current_tok.type == TOK_PLUS || p.current_tok.type == TOK_SUB) {
        let op_tok: Token = p.current_tok;
        parser_advance(p);
        let right: NodeID = term(p);
        let pos: Position = Position(idx=0, ln=op_tok.line, col=op_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
        left = add_binop_node(p.arena, BinOpNode(type=NODE_BINOP, left=left, op_tok=op_tok, right=right, pos=pos));
    }
    
    return left;
}

func var_decl_core(p: Parser, is_const: Bool, anns: Vector(AnnotationNode), allow_inference: Bool) -> NodeID {
    let start_pos: Position = Position(idx=0, ln=p.current_tok.line, col=p.current_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);

    let tid: TypedIdent = parse_typed_name(p, allow_inference);

    if (has_node(tid.type_node)) {
        let t_base: Int = node_tag(tid.type_node);
        if (t_base == NODE_FALLIBLE_TYPE) {
            let err_pos: Position = Position(idx=0, ln=tid.name_tok.line, col=tid.name_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
            throw_invalid_syntax(err_pos, "Variables cannot be declared with fallible types (?). Did you forget to try unwrap '?' or use a catch block?");
        }
    }

    let val_node: NodeID = NO_NODE;
    if (p.current_tok.type == TOK_ASSIGN) {
        parser_advance(p);
        val_node = expression(p);
    }
    
    let declaration: VarDeclareNode = VarDeclareNode(type=NODE_VAR_DECL, name_tok=tid.name_tok, type_node=tid.type_node, value=val_node, is_const=is_const, annotations=anns, pos=start_pos, alloc_id=0);
    return add_var_decl_node(p.arena, declaration);
}

func var_decl(p: Parser, anns: Vector(AnnotationNode), allow_inference: Bool) -> NodeID {
    let is_const: Bool = false;
    if (p.current_tok.type == TOK_CONST) {
        is_const = true;
    }
    parser_advance(p); // skip 'let' or 'const'
    return var_decl_core(p, is_const, anns, allow_inference);
}

func parse_block(p: Parser) -> NodeID {
    let pos: Position = Position(idx=0, ln=p.current_tok.line, col=p.current_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
    if (!parser_enter(p, pos)) {
        if (p.current_tok.type == TOK_LBRACE) { skip_group(p, TOK_LBRACE, TOK_RBRACE); }
        return add_block_node(p.arena, BlockNode(type=NODE_BLOCK, stmts=[]));
    }
    let result: NodeID = parse_block_inner(p);
    parser_leave(p);
    return result;
}

func parse_block_inner(p: Parser) -> NodeID {
    // '{'
    if (p.current_tok.type != TOK_LBRACE) {
        let err_pos: Position = Position(idx=0, ln=p.current_tok.line, col=p.current_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
        throw_invalid_syntax(err_pos, "Expected '{' to start a block. ");
    }
    parser_advance(p); // skip {

    let stmts: Vector(NodeID) = [];
    while (p.current_tok.type != TOK_RBRACE && p.current_tok.type != TOK_EOF) {
        let stmt: NodeID = statement(p);
        let base: Int = node_tag(stmt);
        let is_compound: Bool = false;
        if (base != 0 && (base == NODE_IF || base == NODE_BLOCK || base == NODE_WHILE || base == NODE_FOR || base == NODE_FUNC_DEF || base == NODE_CATCH)) {
            is_compound = true;
        }

        if (p.current_tok.type == TOK_SEMICOLON) {
            parser_advance(p);
        } else {
            if (!is_compound) {
                let err_pos: Position = Position(idx=0, ln=p.current_tok.line, col=p.current_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
                throw_invalid_syntax(err_pos, "Expected ';' after statement in block. ");
                synchronize(p);
            }
        }
        
        if (p.current_tok.type == TOK_CATCH) {
            let catch_pos: Position = Position(idx=0, ln=p.current_tok.line, col=p.current_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
            parser_advance(p); // skip catch
            
            if (p.current_tok.type != TOK_LPAREN) {
                let err_pos: Position = Position(idx=0, ln=p.current_tok.line, col=p.current_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
                throw_invalid_syntax(err_pos, "Expected '(' after 'catch'. ");
            }
            parser_advance(p);
            
            let err_name: Token = null;
            if (is_name_token(p.current_tok.type)) {
                err_name = p.current_tok;
                parser_advance(p);
            } else {
                let err_pos: Position = Position(idx=0, ln=p.current_tok.line, col=p.current_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
                throw_invalid_syntax(err_pos, "Expected identifier for catch variable. ");
            }
            
            if (p.current_tok.type != TOK_RPAREN) {
                let err_pos: Position = Position(idx=0, ln=p.current_tok.line, col=p.current_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
                throw_invalid_syntax(err_pos, "Expected ')' after catch variable. ");
            }
            parser_advance(p);
            
            let catch_body: NodeID = parse_block(p);
            stmt = add_catch_node(p.arena, CatchNode(type=NODE_CATCH, stmt=stmt, err_name=err_name, body=catch_body, pos=catch_pos, alloc_id=0));
        }

        if (has_node(stmt)) {
            stmts.append(stmt);
        }
    }
    if (p.current_tok.type != TOK_RBRACE) {
        let err_pos: Position = Position(idx=0, ln=p.current_tok.line, col=p.current_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
        throw_invalid_syntax(err_pos, "Expected '}' to close block. ");
    }
    parser_advance(p); // skip }

    return add_block_node(p.arena, BlockNode(type=NODE_BLOCK, stmts=stmts));
}

func if_stmt(p: Parser) -> NodeID {
    let if_tok: Token = p.current_tok;
    parser_advance(p); // skip 'if'
    
    let cond: NodeID = atom(p);
    let body: NodeID = parse_block(p);

    let else_body: NodeID = NO_NODE;
    if (p.current_tok.type == TOK_ELSE) {
        parser_advance(p); // skip 'else'
        
        if (p.current_tok.type == TOK_IF) { // else if
            else_body = if_stmt(p);
        } else {
            else_body = parse_block(p);
        }
    }
    
    let pos: Position = Position(idx=0, ln=if_tok.line, col=if_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
    return add_if_node(p.arena, IfNode(type=NODE_IF, condition=cond, body=body, else_body=else_body, pos=pos));
}

func while_stmt(p: Parser) -> NodeID {
    let while_tok: Token = p.current_tok;
    parser_advance(p); // skip 'while'
    let cond: NodeID = atom(p);
    let body: NodeID = parse_block(p);

    let pos: Position = Position(idx=0, ln=while_tok.line, col=while_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
    return add_while_node(p.arena, WhileNode(type=NODE_WHILE, condition=cond, body=body, pos=pos));
}

func break_stmt(p: Parser) -> NodeID {
    let tok: Token = p.current_tok;
    parser_advance(p);
    let pos: Position = Position(idx=0, ln=tok.line, col=tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
    return add_break_node(p.arena, BreakNode(type=NODE_BREAK, pos=pos));
}

func continue_stmt(p: Parser) -> NodeID {
    let tok: Token = p.current_tok;
    parser_advance(p);
    let pos: Position = Position(idx=0, ln=tok.line, col=tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
    return add_continue_node(p.arena, ContinueNode(type=NODE_CONTINUE, pos=pos));
}

func for_stmt(p: Parser) -> NodeID {
    let for_tok: Token = p.current_tok;
    parser_advance(p); // skip 'for'

    if (p.current_tok.type != TOK_LPAREN) {
        let err_pos: Position = Position(idx=0, ln=p.current_tok.line, col=p.current_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
        throw_invalid_syntax(err_pos, "Expected '(' after 'for'. ");
    }
    parser_advance(p); // skip '('

    let init: NodeID = NO_NODE;
    if (p.current_tok.type == TOK_SEMICOLON) {
        init = NO_NODE;
    } else {
        if (p.current_tok.type == TOK_LET) {
            init = var_decl(p, [], true);
        } else if ((is_name_token(p.current_tok.type) && (peek_type(p) == TOK_TYPE_ARROW || peek_type(p) == TOK_COLON)) || (p.current_tok.type == TOK_PTR)) {
            init = var_decl_core(p, false, [], false);
        } else {
            init = expression(p);    // i = 0
        }
    }

    if (p.current_tok.type != TOK_SEMICOLON) {
        let err_pos: Position = Position(idx=0, ln=p.current_tok.line, col=p.current_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
        throw_invalid_syntax(err_pos, "Expected ';' after for-init. ");
    }
    parser_advance(p); // skip ';'

    let cond: NodeID = NO_NODE;
    if (p.current_tok.type != TOK_SEMICOLON) {
        cond = expression(p);
    }

    if (p.current_tok.type != TOK_SEMICOLON) {
        let err_pos: Position = Position(idx=0, ln=p.current_tok.line, col=p.current_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
        throw_invalid_syntax(err_pos, "Expected ';' after for-condition. ");
    }
    parser_advance(p); // skip ';'

    let step: NodeID = NO_NODE;
    if (p.current_tok.type != TOK_RPAREN) {
        step = expression(p);
    }

    if (p.current_tok.type != TOK_RPAREN) {
        let err_pos: Position = Position(idx=0, ln=p.current_tok.line, col=p.current_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
        throw_invalid_syntax(err_pos, "Expected ')' after for-step. ");
    }
    parser_advance(p); // skip ')'

    let body: NodeID = parse_block(p);
    let pos: Position = Position(idx=0, ln=for_tok.line, col=for_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
    return add_for_node(p.arena, ForNode(type=NODE_FOR, init=init, cond=cond, step=step, body=body, pos=pos));
}

func statement(p: Parser) -> NodeID {
    let anns: Vector(AnnotationNode) = [];
    if (p.current_tok.type == TOK_AT) {
        anns = parse_annotations(p);
    }

    if (p.current_tok.type == TOK_LET || p.current_tok.type == TOK_CONST) { 
        return var_decl(p, anns, true); 
    }
    if (p.current_tok.type == TOK_FUNC) { 
        return func_def(p, anns); 
    }

    if (anns.length() > 0) {
        let err_pos: Position = Position(idx=0, ln=p.current_tok.line, col=p.current_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
        throw_invalid_syntax(err_pos, "Annotations are only allowed on declarations (func, let, const, etc.).");
    }

    if (p.current_tok.type == TOK_IF)  { return if_stmt(p); }
    if (p.current_tok.type == TOK_WHILE) { return while_stmt(p); }
    if (p.current_tok.type == TOK_LBRACE) { return parse_block(p); }
    if (p.current_tok.type == TOK_BREAK) { return break_stmt(p); }
    if (p.current_tok.type == TOK_CONTINUE) { return continue_stmt(p); }
    if (p.current_tok.type == TOK_FOR) { return for_stmt(p); }
    if (p.current_tok.type == TOK_RETURN) { return return_stmt(p); }
    if (p.current_tok.type == TOK_THROW) { return throw_stmt(p); }

    return expression(p);
}


func is_default_param(arena: AstArena, node: NodeID) -> Bool {
    if (!has_node(node)) { return false; }
    let base: Int = node_tag(node);
    if (base == NODE_INT || base == NODE_FLOAT || base == NODE_STRING ||
        base == NODE_CHAR || base == NODE_BOOL || base == NODE_NULL ||
        base == NODE_NULLPTR) {
        return true;
    }
    if (base == NODE_UNARYOP) {
        let unary: UnaryOpNode = get_unary_node(arena, node);
        return is_default_param(arena, unary.node);
    }
    if (base == NODE_BINOP) {
        let binary: BinOpNode = get_binop_node(arena, node);
        return is_default_param(arena, binary.left) && is_default_param(arena, binary.right);
    }
    return false;
}

func parse_params(p: Parser, callable: Bool) -> Vector(ParamNode) {
    if (p.current_tok.type == TOK_RPAREN) {
        return null;
    }
    let params: Vector(ParamNode) = [];

    let saw_variadic: Bool = false;
    let saw_default: Bool = false;
    while (p.current_tok.type != TOK_RPAREN && p.current_tok.type != TOK_EOF) {
        let tid: TypedIdent = parse_typed_name(p, false);
        let pos: Position = Position(idx=0, ln=tid.name_tok.line, col=tid.name_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
        let is_variadic: Bool = false;
        if (p.current_tok.type == TOK_ELLIPSIS) {
            if (!callable) {
                throw_invalid_syntax(pos, "Variadic parameters are only allowed in functions and methods.");
            } else if (saw_variadic) {
                throw_invalid_syntax(pos, "A parameter list can contain only one variadic parameter.");
            }
            is_variadic = true;
            saw_variadic = true;
            parser_advance(p);
        }

        let default_val: NodeID = NO_NODE;
        if (p.current_tok.type == TOK_ASSIGN) {
            if (!callable) {
                throw_invalid_syntax(pos, "Default values are only allowed in functions and methods.");
            } else if is_variadic {
                throw_invalid_syntax(pos, "A variadic parameter cannot have a default value.");
            }
            parser_advance(p);
            default_val = expression(p);
            if (!is_default_param(p.arena, default_val)) {
                throw_invalid_syntax(pos, "A default parameter value must be a constant expression.");
            }
            saw_default = true;
        } else if (saw_default && !saw_variadic) {
            throw_invalid_syntax(pos, "A required parameter cannot follow a parameter with a default value.");
        }

        params.append(ParamNode(type=NODE_PARAM, name_tok=tid.name_tok, type_tok=tid.type_node, pos=pos, is_variadic=is_variadic, default_val=default_val));
        if (p.current_tok.type != TOK_COMMA) { break; }
        parser_advance(p);
    }
    return params;
}

func func_def(p: Parser, anns: Vector(AnnotationNode)) -> NodeID {
    let func_tok: Token = p.current_tok;
    parser_advance(p); // skip 'func'
    
    if (!is_name_token(p.current_tok.type)) {
        let err_pos: Position = Position(idx=0, ln=p.current_tok.line, col=p.current_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
        throw_invalid_syntax(err_pos, "expected a function name after 'func'");
    }
    let name_tok: Token = p.current_tok;
    parser_advance(p);

    let type_params: Vector(GenericParamNode) = null;
    if (p.current_tok.type == TOK_LT) {
        type_params = parse_type_params(p);
    }

    if (p.current_tok.type != TOK_LPAREN) {
        let err_pos: Position = Position(idx=0, ln=p.current_tok.line, col=p.current_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
        throw_invalid_syntax(err_pos, "Expected '(' after function name.");
    }
    parser_advance(p); // skip '('
    
    let params: Vector(ParamNode) = parse_params(p, true);
    
    if (p.current_tok.type != TOK_RPAREN) {
        let err_pos: Position = Position(idx=0, ln=p.current_tok.line, col=p.current_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
        throw_invalid_syntax(err_pos, "Expected ')' after parameters.");
    }
    parser_advance(p); // skip ')'
    
    // -> RetType
    if (p.current_tok.type != TOK_TYPE_ARROW) {
        let err_pos: Position = Position(idx=0, ln=p.current_tok.line, col=p.current_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
        throw_invalid_syntax(err_pos, "Expected '->' for return type.");
    }
    parser_advance(p);

    let ret_type_node: NodeID = parse_return_type(p);

    let body: NodeID = parse_block(p);
    
    let pos: Position = Position(idx=0, ln=func_tok.line, col=func_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
    let definition: FunctionDefNode = FunctionDefNode(type=NODE_FUNC_DEF, name_tok=name_tok, type_params=type_params, params=params, ret_type_tok=ret_type_node, body=body, annotations=anns, pos=pos);
    return add_func_def_node(p.arena, definition);
}

func return_stmt(p: Parser) -> NodeID {
    let ret_tok: Token = p.current_tok;
    parser_advance(p);
    
    let val: NodeID = NO_NODE;
    if (p.current_tok.type != TOK_SEMICOLON) {
        val = expression(p);
    }
    
    let pos: Position = Position(idx=0, ln=ret_tok.line, col=ret_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
    return add_return_node(p.arena, ReturnNode(type=NODE_RETURN, value=val, pos=pos));
}

func throw_stmt(p: Parser) -> NodeID {
    let throw_tok: Token = p.current_tok;
    parser_advance(p);
    
    let val: NodeID = expression(p);
    
    let pos: Position = Position(idx=0, ln=throw_tok.line, col=throw_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
    return add_throw_node(p.arena, ThrowNode(type=NODE_THROW, value=val, pos=pos));
}

func parse_struct_def(p: Parser, anns: Vector(AnnotationNode)) -> NodeID {
    let start_pos: Position = Position(idx=0, ln=p.current_tok.line, col=p.current_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);

    parser_advance(p); // skip 'struct'

    if (!is_name_token(p.current_tok.type)) {
        let err_pos: Position = Position(idx=0, ln=p.current_tok.line, col=p.current_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
        throw_invalid_syntax(err_pos, "Expected struct name.");
    }
    let name_tok: Token = p.current_tok;
    parser_advance(p);

    let type_params: Vector(GenericParamNode) = null;
    if (p.current_tok.type == TOK_LT) {
        type_params = parse_type_params(p);
    }

    if (p.current_tok.type != TOK_LPAREN) {
        let err_pos: Position = Position(idx=0, ln=p.current_tok.line, col=p.current_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
        throw_invalid_syntax(err_pos, "Expected '(' after struct name.");
    }
    parser_advance(p); // skip '('

    let fields: Vector(ParamNode) = parse_params(p, false);

    if (p.current_tok.type != TOK_RPAREN) {
        let err_pos: Position = Position(idx=0, ln=p.current_tok.line, col=p.current_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
        throw_invalid_syntax(err_pos, "Expected ')' after struct fields.");
    }
    parser_advance(p); // skip ')'

    let body: NodeID = NO_NODE;
    if (p.current_tok.type == TOK_LBRACE) {
        body = parse_block(p); // initialization
    }
    return add_struct_def_node(p.arena, StructDefNode(type=NODE_STRUCT_DEF, name_tok=name_tok, type_params=type_params, fields=fields, body=body, annotations=anns, pos=start_pos));
}

func parse_extern_func(p: Parser) -> NodeID {
    let start_pos: Position = Position(idx=0, ln=p.current_tok.line, col=p.current_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
    parser_advance(p); // skip 'func'
    
    if (!is_name_token(p.current_tok.type)) {
        let err_pos: Position = Position(idx=0, ln=p.current_tok.line, col=p.current_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
        throw_invalid_syntax(err_pos, "Expected function name in extern block.");
    }
    let name_tok: Token = p.current_tok;
    parser_advance(p);
    
    if (p.current_tok.type != TOK_LPAREN) {
        let err_pos: Position = Position(idx=0, ln=p.current_tok.line, col=p.current_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
        throw_invalid_syntax(err_pos, "Expected '(' after function name.");
    }
    parser_advance(p); // skip '('

    let params: Vector(ParamNode) = [];
    let is_varargs: Bool = false;
    
    if (p.current_tok.type != TOK_RPAREN) {
        while (true) {
            if (p.current_tok.type == TOK_ELLIPSIS) {
                is_varargs = true;
 
                parser_advance(p); // skip ...
                if (p.current_tok.type == TOK_COMMA) {
                    let err_pos: Position = Position(idx=0, ln=p.current_tok.line, col=p.current_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
                    throw_invalid_syntax(err_pos, "Varargs '...' must be the last parameter.");
      
                }
                break;
            } else {
                let tid: TypedIdent = parse_typed_name(p, false);
                let param_pos: Position = Position(idx=0, ln=tid.name_tok.line, col=tid.name_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
                let new_param: ParamNode = ParamNode(type=NODE_PARAM, name_tok=tid.name_tok, type_tok=tid.type_node, pos=param_pos);

                params.append(new_param);

                if (p.current_tok.type == TOK_COMMA) {
                    parser_advance(p);
                } else {
                    break;
                }
            }
        }
    }
    
    if (p.current_tok.type != TOK_RPAREN) {
        let err_pos: Position = Position(idx=0, ln=p.current_tok.line, col=p.current_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
        throw_invalid_syntax(err_pos, "Expected ')' after extern parameters.");
    }
    parser_advance(p); // skip ')'
    
    let ret_type: NodeID = NO_NODE;
    if (p.current_tok.type == TOK_TYPE_ARROW) {
        parser_advance(p);
        ret_type = parse_return_type(p);
    } else {
        let err_pos: Position = Position(idx=0, ln=p.current_tok.line, col=p.current_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
        throw_invalid_syntax(err_pos, "Expected return type ('-> Type').");
    }
    
    let declaration: ExternFuncNode = ExternFuncNode(type=NODE_EXTERN_FUNC, name_tok=name_tok, params=params, ret_type_tok=ret_type, is_varargs=is_varargs, abi_name="", link_name="", pos=start_pos);
    return add_extern_func_node(p.arena, declaration);
}

func parse_extern(p: Parser) -> NodeID {
    let start_pos: Position = Position(idx=0, ln=p.current_tok.line, col=p.current_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
    parser_advance(p); // skip 'extern'

    if (p.current_tok.type == TOK_STR_LIT) {
        let abi_name: String = p.current_tok.value;
        let link_name: String = "";
        parser_advance(p); // skip abi

        if (p.current_tok.type == TOK_IN) {
            parser_advance(p); // skip 'in'
            if (p.current_tok.type != TOK_STR_LIT) {
                let err_pos: Position = Position(idx=0, ln=p.current_tok.line, col=p.current_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
                throw_invalid_syntax(err_pos, "Expected library name after 'in'.");
            }
            link_name = p.current_tok.value;
            parser_advance(p); // skip library
        }

        if (p.current_tok.type != TOK_LBRACE) {
            let err_pos: Position = Position(idx=0, ln=p.current_tok.line, col=p.current_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
            throw_invalid_syntax(err_pos, "Expected '{' to start extern block.");
        }
        parser_advance(p); // skip '{'

        let funcs: Vector(NodeID) = [];
        while (p.current_tok.type != TOK_RBRACE && p.current_tok.type != TOK_EOF) {
            if (p.current_tok.type != TOK_FUNC) {
                let err_pos: Position = Position(idx=0, ln=p.current_tok.line, col=p.current_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
                throw_invalid_syntax(err_pos, "Only function declarations are allowed in extern blocks.");
                break;
            }

            let func_node: NodeID = parse_extern_func(p);
            let f_node: ExternFuncNode = get_extern_func_node(p.arena, func_node);
            f_node.abi_name = abi_name;
            f_node.link_name = link_name;

            if (p.current_tok.type != TOK_SEMICOLON) {
                let err_pos: Position = Position(idx=0, ln=p.current_tok.line, col=p.current_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
                throw_invalid_syntax(err_pos, "Expected ';' after extern function declaration.");
            }
            parser_advance(p); // skip ';'
            funcs.append(func_node);
        }

        if (p.current_tok.type != TOK_RBRACE) {
            let err_pos: Position = Position(idx=0, ln=p.current_tok.line, col=p.current_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
            throw_invalid_syntax(err_pos, "Expected '}' to end extern block.");
        }
        parser_advance(p); // skip '}'
        return add_extern_block_node(p.arena, ExternBlockNode(type=NODE_EXTERN_BLOCK, funcs=funcs, abi_name=abi_name, link_name=link_name, pos=start_pos));
    }

    if (p.current_tok.type == TOK_FUNC) {
        let func_node: NodeID = parse_extern_func(p);

        if (p.current_tok.type != TOK_FROM) {
            let err_pos: Position = Position(idx=0, ln=p.current_tok.line, col=p.current_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
            throw_invalid_syntax(err_pos, "Expected 'from' after extern function declaration.");
        }
        parser_advance(p); // skip 'from'

        if (p.current_tok.type != TOK_STR_LIT) {
            let err_pos: Position = Position(idx=0, ln=p.current_tok.line, col=p.current_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
            throw_invalid_syntax(err_pos, "Expected ABI name after 'from'.");
        }
        let abi_name: String = p.current_tok.value;
        let link_name: String = "";
        parser_advance(p); // skip abi

        if (p.current_tok.type == TOK_IN) {
            parser_advance(p); // skip 'in'
            if (p.current_tok.type != TOK_STR_LIT) {
                let err_pos: Position = Position(idx=0, ln=p.current_tok.line, col=p.current_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
                throw_invalid_syntax(err_pos, "Expected library name after 'in'.");
            }
            link_name = p.current_tok.value;
            parser_advance(p); // skip library
        }

        if (p.current_tok.type != TOK_SEMICOLON) {
            let err_pos: Position = Position(idx=0, ln=p.current_tok.line, col=p.current_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
            throw_invalid_syntax(err_pos, "Expected ';' at the end of extern declaration.");
        }
        parser_advance(p); // skip ';'

        let f_node: ExternFuncNode = get_extern_func_node(p.arena, func_node);
        f_node.abi_name = abi_name;
        f_node.link_name = link_name;
        p.arena.extern_func_nodes[node_slot(func_node)] = f_node;
        let funcs: Vector(NodeID) = [func_node];
        return add_extern_block_node(p.arena, ExternBlockNode(type=NODE_EXTERN_BLOCK, funcs=funcs, abi_name=abi_name, link_name=link_name, pos=start_pos));
    }

    let err_pos: Position = Position(idx=0, ln=p.current_tok.line, col=p.current_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
    throw_invalid_syntax(err_pos, "Expected an ABI string or 'func' after 'extern'.");
    return NO_NODE;
}

func parse_import(p: Parser) -> NodeID {
    let start_pos: Position = Position(idx=0, ln=p.current_tok.line, col=p.current_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
    parser_advance(p); // skip 'import'

    let symbols: Vector(ImportSymbolNode) = null;
    let path_tok: Token = null;

    // import * from "..."
    if (p.current_tok.type == TOK_MUL) {
        symbols = [];
        let star_tok: Token = p.current_tok;
        parser_advance(p); // skip '*'

        symbols.append(ImportSymbolNode(name_tok=star_tok, alias_tok=null));
        
        if (p.current_tok.type != TOK_FROM) {
            let err_pos: Position = Position(idx=0, ln=p.current_tok.line, col=p.current_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
            throw_invalid_syntax(err_pos, "Expected 'from' after '*'.");
        }
        parser_advance(p); // skip 'from'
    }

    // import A, B from "..."
    else if (is_name_token(p.current_tok.type)) {
        symbols = [];
        let parsing: Bool = true;
        while parsing {
            if (!is_name_token(p.current_tok.type)) {
                let err_pos: Position = Position(idx=0, ln=p.current_tok.line, col=p.current_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
                throw_invalid_syntax(err_pos, "Expected identifier in import list.");
            }
            
            let name_tok: Token = p.current_tok;
            parser_advance(p); // skip name

            let alias_tok: Token = null;
            if (p.current_tok.type == TOK_AS) {
                parser_advance(p); // skip 'as'
                if (!is_name_token(p.current_tok.type)) {
                    let err_pos: Position = Position(idx=0, ln=p.current_tok.line, col=p.current_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
                    throw_invalid_syntax(err_pos, "Expected identifier after 'as'.");
                }
                alias_tok = p.current_tok;
                parser_advance(p); // skip alias name
            }

            let node: ImportSymbolNode = ImportSymbolNode(name_tok=name_tok, alias_tok=alias_tok);
            symbols.append(node);

            if (p.current_tok.type == TOK_COMMA) {
                parser_advance(p); // skip ','
            } else {
                parsing = false;
            }
        }

        if (p.current_tok.type != TOK_FROM) {
            let err_pos: Position = Position(idx=0, ln=p.current_tok.line, col=p.current_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
            throw_invalid_syntax(err_pos, "Expected 'from' after import symbols.");
        }
        parser_advance(p); // skip 'from'
    }

    if (p.current_tok.type != TOK_STR_LIT) {
        let err_pos: Position = Position(idx=0, ln=p.current_tok.line, col=p.current_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
        throw_invalid_syntax(err_pos, "Expected string literal for import path.");
    }
    path_tok = p.current_tok;
    parser_advance(p); // skip string

    let alias_tok: Token = null;
    if (p.current_tok.type == TOK_AS) {
        if (symbols is !null) {
            let err_pos: Position = Position(idx=0, ln=p.current_tok.line, col=p.current_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
            throw_invalid_syntax(err_pos, "A module alias can only be used with 'import \"module\" as name'. Alias imported symbols before 'from'.");
        }
        parser_advance(p); // skip 'as'
        if (!is_name_token(p.current_tok.type)) {
            let err_pos: Position = Position(idx=0, ln=p.current_tok.line, col=p.current_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
            throw_invalid_syntax(err_pos, "Expected identifier after 'as' for module alias.");
        }
        alias_tok = p.current_tok;
        parser_advance(p); // skip alias identifier
    }

    if (p.current_tok.type == TOK_SEMICOLON) {
        parser_advance(p);
    }

    return add_import_node(p.arena, ImportNode(type=NODE_IMPORT, path_tok=path_tok, symbols=symbols, alias_tok=alias_tok, pos=start_pos));
}

func parse_interface_def(p: Parser, anns: Vector(AnnotationNode)) -> NodeID {
    let pos: Position = Position(idx=0, ln=p.current_tok.line, col=p.current_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
    parser_advance(p); // skip 'interface'

    if (!is_name_token(p.current_tok.type)) {
        let err_pos: Position = Position(idx=0, ln=p.current_tok.line, col=p.current_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
        throw_invalid_syntax(err_pos, "Expected interface name.");
    }
    let name_tok: Token = p.current_tok;
    parser_advance(p);

    let type_params: Vector(GenericParamNode) = null;
    if (p.current_tok.type == TOK_LT) {
        type_params = parse_type_params(p);
    }

    let interfaces: Vector(NodeID) = [];
    if (p.current_tok.type == TOK_WITH) {
        parser_advance(p); // skip 'with'
        interfaces.append(parse_return_type(p));
        while (p.current_tok.type == TOK_COMMA) {
            parser_advance(p); // skip ','
            interfaces.append(parse_return_type(p));
        }
    }

    if (p.current_tok.type != TOK_LBRACE) {
        let err_pos: Position = Position(idx=0, ln=p.current_tok.line, col=p.current_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
        throw_invalid_syntax(err_pos, "Expected '{' before interface body.");
    }
    parser_advance(p); // skip '{'

    let methods: Vector(NodeID) = [];

    while (p.current_tok.type != TOK_RBRACE && p.current_tok.type != TOK_EOF) {
        let member_anns: Vector(AnnotationNode) = [];
        if (p.current_tok.type == TOK_AT) {
            member_anns = parse_annotations(p);
        }

        if (p.current_tok.type == TOK_METHOD) {
            let err_pos: Position = Position(idx=0, ln=p.current_tok.line, col=p.current_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
            throw_invalid_syntax(err_pos, "Use 'func' to declare interface methods; 'method' was removed in White Language 0.3.5.");
        }

        if (p.current_tok.type == TOK_METHOD || p.current_tok.type == TOK_FUNC) {
            let m_pos: Position = Position(idx=0, ln=p.current_tok.line, col=p.current_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
            parser_advance(p);
            let m_name: Token = p.current_tok;
            parser_advance(p);

            let type_params: Vector(GenericParamNode) = null;
            if (p.current_tok.type == TOK_LT) {
                type_params = parse_type_params(p);
            }

            if (p.current_tok.type != TOK_LPAREN) {
                let err_pos: Position = Position(idx=0, ln=p.current_tok.line, col=p.current_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
                throw_invalid_syntax(err_pos, "Expected '(' after method name.");
            }
            parser_advance(p); // skip '('

            let params: Vector(ParamNode) = parse_params(p, true); 

            if (p.current_tok.type != TOK_RPAREN) {
                let err_pos: Position = Position(idx=0, ln=p.current_tok.line, col=p.current_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
                throw_invalid_syntax(err_pos, "Expected ')' after parameters.");
            }
            parser_advance(p); // skip ')'

            let void_tok: Token = Token(type=TOK_T_VOID, value="Void", line=m_pos.ln, col=m_pos.col);
            let ret_type: NodeID = add_var_access_node(p.arena, VarAccessNode(type=NODE_VAR_ACCESS, name_tok=void_tok, pos=m_pos));
            if (p.current_tok.type == TOK_TYPE_ARROW) {
                parser_advance(p);
                ret_type = parse_return_type(p);
            }

            if (p.current_tok.type != TOK_SEMICOLON) {
                let err_pos: Position = Position(idx=0, ln=p.current_tok.line, col=p.current_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
                throw_invalid_syntax(err_pos, "Expected ';' after interface method declaration. Interface methods cannot have bodies.");
            }
            parser_advance(p); // skip ';'

            let declaration: MethodDefNode = MethodDefNode(type=NODE_METHOD_DEF, pos=m_pos, name_tok=m_name, type_params=type_params, params=params, return_type=ret_type, body=NO_NODE, is_override=false, annotations=member_anns);
            methods.append(add_method_def_node(p.arena, declaration));

        } else {
            let err_pos: Position = Position(idx=0, ln=p.current_tok.line, col=p.current_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
            throw_invalid_syntax(err_pos, "Interfaces can only contain function declarations.");
            break;
        }
    }

    if (p.current_tok.type != TOK_RBRACE) {
        let err_pos: Position = Position(idx=0, ln=p.current_tok.line, col=p.current_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
        throw_invalid_syntax(err_pos, "Expected '}' after interface body.");
    }
    parser_advance(p); // skip '}'

    let definition: InterfaceDefNode = InterfaceDefNode(type=NODE_INTERFACE_DEF, name_tok=name_tok, type_params=type_params, interfaces=interfaces, methods=methods, annotations=anns, pos=pos);
    return add_interface_def_node(p.arena, definition);
}

func parse_class_def(p: Parser, anns: Vector(AnnotationNode)) -> NodeID {
    let pos: Position = Position(idx=0, ln=p.current_tok.line, col=p.current_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
    parser_advance(p); // skip 'class'

    if (!is_name_token(p.current_tok.type)) {
        let err_pos: Position = Position(idx=0, ln=p.current_tok.line, col=p.current_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
        throw_invalid_syntax(err_pos, "Expected class name.");
    }
    let name_tok: Token = p.current_tok;
    parser_advance(p);

    let type_params: Vector(GenericParamNode) = null;
    if (p.current_tok.type == TOK_LT) {
        type_params = parse_type_params(p);
    }

    let parent_tok: NodeID = NO_NODE;
    if (p.current_tok.type == TOK_LPAREN) {
        parser_advance(p); // skip '('
        parent_tok = parse_return_type(p);
        if (p.current_tok.type != TOK_RPAREN) {
            let err_pos: Position = Position(idx=0, ln=p.current_tok.line, col=p.current_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
            throw_invalid_syntax(err_pos, "Expected ')' after parent class name.");
        }
        parser_advance(p); // skip ')'
    }

    let interfaces: Vector(NodeID) = [];
    if (p.current_tok.type == TOK_WITH) {
        parser_advance(p); // skip 'with'
        interfaces.append(parse_return_type(p));
        
        while (p.current_tok.type == TOK_COMMA) {
            parser_advance(p); // skip ','
            interfaces.append(parse_return_type(p));
        }
    }

    if (p.current_tok.type != TOK_LBRACE) {
        let err_pos: Position = Position(idx=0, ln=p.current_tok.line, col=p.current_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
        throw_invalid_syntax(err_pos, "Expected '{' before class body.");
    }
    parser_advance(p); // skip '{'

    let fields: Vector(NodeID) = [];
    let methods: Vector(NodeID) = [];

    while (p.current_tok.type != TOK_RBRACE && p.current_tok.type != TOK_EOF) {
        let member_anns: Vector(AnnotationNode) = [];
        if (p.current_tok.type == TOK_AT) {
            member_anns = parse_annotations(p);
        }

        if (p.current_tok.type == TOK_METHOD) {
            let err_pos: Position = Position(idx=0, ln=p.current_tok.line, col=p.current_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
            throw_invalid_syntax(err_pos, "Use 'func' to declare class methods; 'method' was removed in White Language 0.3.5.");
        }

        if (p.current_tok.type == TOK_LET) {
            let f_pos: Position = Position(idx=0, ln=p.current_tok.line, col=p.current_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
            parser_advance(p); // skip 'let'

            let tid: TypedIdent = parse_typed_name(p, true);

            let default_val: NodeID = NO_NODE;
            if (p.current_tok.type == TOK_ASSIGN) {
                parser_advance(p); // skip '='
                default_val = expression(p);
            }

            if (p.current_tok.type != TOK_SEMICOLON) {
                let err_pos: Position = Position(idx=0, ln=p.current_tok.line, col=p.current_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
                throw_invalid_syntax(err_pos, "Expected ';' after field declaration.");
            }
            parser_advance(p); // skip ';'

            let field: VarDeclareNode = VarDeclareNode(type=NODE_VAR_DECL, name_tok=tid.name_tok, type_node=tid.type_node, value=default_val, is_const=false, annotations=member_anns, pos=f_pos, alloc_id=0);
            fields.append(add_var_decl_node(p.arena, field));
            
        } else if (p.current_tok.type == TOK_METHOD || p.current_tok.type == TOK_FUNC) {
            let m_pos: Position = Position(idx=0, ln=p.current_tok.line, col=p.current_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
            parser_advance(p);
            let m_name: Token = p.current_tok;
            parser_advance(p);

            let type_params: Vector(GenericParamNode) = null;
            if (p.current_tok.type == TOK_LT) {
                type_params = parse_type_params(p);
            }

            if (p.current_tok.type != TOK_LPAREN) {
                let err_pos: Position = Position(idx=0, ln=p.current_tok.line, col=p.current_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
                throw_invalid_syntax(err_pos, "Expected '(' after method name.");
            }
            parser_advance(p); // skip '('

            let params: Vector(ParamNode) = parse_params(p, true); 

            if (p.current_tok.type != TOK_RPAREN) {
                let err_pos: Position = Position(idx=0, ln=p.current_tok.line, col=p.current_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
                throw_invalid_syntax(err_pos, "Expected ')' after parameters.");
            }
            parser_advance(p); // skip ')'

            if (p.current_tok.type != TOK_TYPE_ARROW) {
                let err_pos: Position = Position(idx=0, ln=p.current_tok.line, col=p.current_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
                throw_invalid_syntax(err_pos, "Expected '->' for return type.");
            }
            parser_advance(p); // skip '->'

            let ret_type: NodeID = parse_return_type(p);

            let body: NodeID = parse_block(p); 
            
            let method_def: MethodDefNode = MethodDefNode(type=NODE_METHOD_DEF, pos=m_pos, name_tok=m_name, type_params=type_params, params=params, return_type=ret_type, body=body, is_override=false, annotations=member_anns);
            methods.append(add_method_def_node(p.arena, method_def));

        } else if (p.current_tok.type == TOK_TYPE) {
            let type_pos: Position = Position(idx=0, ln=p.current_tok.line, col=p.current_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
            if (member_anns.length() > 0) {
                throw_invalid_syntax(type_pos, "Conversion declarations cannot have annotations.");
            }
            parser_advance(p); // skip 'type'

            let target_type: NodeID = parse_return_type(p);
            let type_name_tok: Token = Token(type=TOK_IDENTIFIER, value="$type", line=type_pos.ln, col=type_pos.col);
            let body: NodeID = parse_block(p);

            let conversion: MethodDefNode = MethodDefNode(type=NODE_METHOD_DEF, pos=type_pos, name_tok=type_name_tok, type_params=null, params=[], return_type=target_type, body=body, is_override=false, annotations=null);
            methods.append(add_method_def_node(p.arena, conversion));

        } else if (p.current_tok.type == TOK_IDENTIFIER && p.current_tok.value == "init") {
            let init_pos: Position = Position(idx=0, ln=p.current_tok.line, col=p.current_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
            parser_advance(p); // skip 'init'

            let init_name_tok: Token = Token(type=TOK_IDENTIFIER, value="$init", line=init_pos.ln, col=init_pos.col);
            
            if (p.current_tok.type != TOK_LPAREN) {
                let err_pos: Position = Position(idx=0, ln=p.current_tok.line, col=p.current_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
                throw_invalid_syntax(err_pos, "Expected '(' after init.");
            }
            parser_advance(p); // skip '('

            let params: Vector(ParamNode) = parse_params(p, true); 

            if (p.current_tok.type != TOK_RPAREN) {
                let err_pos: Position = Position(idx=0, ln=p.current_tok.line, col=p.current_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
                throw_invalid_syntax(err_pos, "Expected ')' after parameters.");
            }
            parser_advance(p); // skip ')'

            let void_tok: Token = Token(type=TOK_T_VOID, value="Void", line=init_pos.ln, col=init_pos.col);
            let ret_type: NodeID = add_var_access_node(p.arena, VarAccessNode(type=NODE_VAR_ACCESS, name_tok=void_tok, pos=init_pos));
            if (p.current_tok.type == TOK_TYPE_ARROW) {
                parser_advance(p);
                parse_return_type(p);
            }

            let body: NodeID = parse_block(p); 
            
            let initializer: MethodDefNode = MethodDefNode(type=NODE_METHOD_DEF, pos=init_pos, name_tok=init_name_tok, type_params=null, params=params, return_type=ret_type, body=body, is_override=false, annotations=member_anns);
            methods.append(add_method_def_node(p.arena, initializer));

        } else if (p.current_tok.type == TOK_IDENTIFIER && p.current_tok.value == "deinit") {
            let deinit_pos: Position = Position(idx=0, ln=p.current_tok.line, col=p.current_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
            parser_advance(p); // skip 'deinit'

            let deinit_name_tok: Token = Token(type=TOK_IDENTIFIER, value="$deinit", line=deinit_pos.ln, col=deinit_pos.col);
            
            if (p.current_tok.type != TOK_LPAREN) {
                let err_pos: Position = Position(idx=0, ln=p.current_tok.line, col=p.current_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
                throw_invalid_syntax(err_pos, "Expected '(' after deinit.");
            }
            parser_advance(p); // skip '('

            let params: Vector(ParamNode) = parse_params(p, true);

            if (p.current_tok.type != TOK_RPAREN) {
                let err_pos: Position = Position(idx=0, ln=p.current_tok.line, col=p.current_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
                throw_invalid_syntax(err_pos, "Expected ')' after parameters.");
            }
            parser_advance(p); // skip ')'

            let void_tok: Token = Token(type=TOK_T_VOID, value="Void", line=deinit_pos.ln, col=deinit_pos.col);
            let ret_type: NodeID = add_var_access_node(p.arena, VarAccessNode(type=NODE_VAR_ACCESS, name_tok=void_tok, pos=deinit_pos));
            if (p.current_tok.type == TOK_TYPE_ARROW) {
                parser_advance(p);
                parse_return_type(p);
            }

            let body: NodeID = parse_block(p); 
            let deinitializer: MethodDefNode = MethodDefNode(type=NODE_METHOD_DEF, pos=deinit_pos, name_tok=deinit_name_tok, type_params=null, params=params, return_type=ret_type, body=body, is_override=false, annotations=member_anns);
            methods.append(add_method_def_node(p.arena, deinitializer));

        } else {
            let err_pos: Position = Position(idx=0, ln=p.current_tok.line, col=p.current_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
            throw_invalid_syntax(err_pos, "Expected a field, method, conversion, init, or deinit declaration.");
        }
    }

    if (p.current_tok.type != TOK_RBRACE) {
        let err_pos: Position = Position(idx=0, ln=p.current_tok.line, col=p.current_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
        throw_invalid_syntax(err_pos, "Expected '}' after class body.");
    }
    parser_advance(p); // skip '}'

    let field_init_stmts: Vector(NodeID) = [];
    let field_idx: Int = 0;
    while (field_idx < fields.length()) {
        let field: VarDeclareNode = get_var_decl_node(p.arena, fields[field_idx]);
        if (has_node(field.value)) {
            let self_tok: Token = Token(
                type=TOK_IDENTIFIER,
                value="self",
                line=field.name_tok.line,
                col=field.name_tok.col
            );
            let self_node: NodeID = add_var_access_node(p.arena, VarAccessNode(
                type=NODE_VAR_ACCESS,
                name_tok=self_tok,
                pos=field.pos
            ));
            field_init_stmts.append(add_field_assign_node(p.arena, FieldAssignNode(
                type=NODE_FIELD_ASSIGN,
                obj=self_node,
                field_name=field.name_tok.value,
                value=field.value,
                pos=field.pos
            )));
        }
        field_idx += 1;
    }

    if (field_init_stmts.length() > 0) {
        let field_init_tok: Token = Token(
            type=TOK_IDENTIFIER,
            value="$field_init",
            line=pos.ln,
            col=pos.col
        );
        let void_tok: Token = Token(
            type=TOK_T_VOID,
            value="Void",
            line=pos.ln,
            col=pos.col
        );
        let return_type: NodeID = add_var_access_node(p.arena, VarAccessNode(
            type=NODE_VAR_ACCESS,
            name_tok=void_tok,
            pos=pos
        ));
        methods.append(add_method_def_node(p.arena, MethodDefNode(
            type=NODE_METHOD_DEF,
            pos=pos,
            name_tok=field_init_tok,
            type_params=null,
            params=[],
            return_type=return_type,
            body=add_block_node(p.arena, BlockNode(type=NODE_BLOCK, stmts=field_init_stmts)),
            is_override=false,
            annotations=null
        )));
    }

    let definition: ClassDefNode = ClassDefNode(type=NODE_CLASS_DEF, pos=pos, name_tok=name_tok, type_params=type_params, parent_tok=parent_tok, interfaces=interfaces, fields=fields, methods=methods, annotations=anns);
    return add_class_def_node(p.arena, definition);
}

func parse_enum_def(p: Parser, anns: Vector(AnnotationNode), is_error: Bool) -> NodeID {
    let start_pos: Position = Position(idx=0, ln=p.current_tok.line, col=p.current_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
    let kind: String = "enum";
    if is_error { kind = "error"; }

    parser_advance(p); // skip 'enum' or 'error'

    if (!is_name_token(p.current_tok.type)) {
        let err_pos: Position = Position(idx=0, ln=p.current_tok.line, col=p.current_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
        throw_invalid_syntax(err_pos, "expected a name after '" + kind + "'");
    }
    let name_tok: Token = p.current_tok;
    parser_advance(p);

    if (p.current_tok.type != TOK_LBRACE) {
        let err_pos: Position = Position(idx=0, ln=p.current_tok.line, col=p.current_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
        throw_invalid_syntax(err_pos, "expected '{' after " + kind + " name '" + name_tok.value + "'");
    }
    parser_advance(p); // skip '{'

    let fields: Vector(EnumFieldNode) = [];

    while (p.current_tok.type != TOK_RBRACE && p.current_tok.type != TOK_EOF) {
        if (!is_name_token(p.current_tok.type)) {
            let err_pos: Position = Position(idx=0, ln=p.current_tok.line, col=p.current_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
            throw_invalid_syntax(err_pos, "expected a member name in " + kind + " '" + name_tok.value + "'");
            parser_advance(p);
            continue;
        }
        let field_name_tok: Token = p.current_tok;
        let field_pos: Position = Position(idx=0, ln=p.current_tok.line, col=p.current_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
        parser_advance(p);

        let value_expr: NodeID = NO_NODE;
        if (p.current_tok.type == TOK_ASSIGN) {
            parser_advance(p); // skip '='
            value_expr = expression(p);
        }

        fields.append(EnumFieldNode(type=NODE_ENUM_FIELD, name_tok=field_name_tok, value=value_expr, pos=field_pos));

        if (p.current_tok.type == TOK_COMMA) {
            parser_advance(p);
        } else if (p.current_tok.type != TOK_RBRACE) {
            let err_pos: Position = Position(idx=0, ln=p.current_tok.line, col=p.current_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
            throw_invalid_syntax(err_pos, "expected ',' or '}' after " + kind + " member '" + field_name_tok.value + "'");
            break;
        }
    }

    if (p.current_tok.type == TOK_RBRACE) {
        parser_advance(p);
    } else {
        let err_pos: Position = Position(idx=0, ln=p.current_tok.line, col=p.current_tok.col, text=p.lexer.text, fn=p.lexer.pos.fn);
        throw_invalid_syntax(err_pos, "expected '}' to close " + kind + " '" + name_tok.value + "'");
    }

    return add_enum_def_node(p.arena, EnumDefNode(type=NODE_ENUM_DEF, name_tok=name_tok, fields=fields, pos=start_pos, annotations=anns, is_error=is_error));
}

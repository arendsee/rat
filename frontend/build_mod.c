#include "build_mod.h"

void link_modifiers(Ws* ws_top){

    // Set default function names for all manifolds
    ws_filter_mod(ws_top, _get_manifolds, _set_default_manifold_function);

    Ws* cs = ws_rfilter(ws_top, ws_recurse_most, _manifold_modifier);

    cs = ws_map_split(cs, ws_split_couplet);

    ws_map_pmod(ws_top, cs, _mod_pathwise);

}

// Find all {label,manifold} couplets
Ws* _get_manifolds(const Ws* ws){
    return ws_rfilter(ws, ws_recurse_most, w_is_manifold);
}

// Given the couplet {Label, Manifold}, transfer the name from Label to
// Manifold->function IFF it is not already defined.
void _set_default_manifold_function(const W* cm){
    Manifold* m = g_manifold(g_rhs(cm));
    if(!m->function){
        m->function = strdup(g_label(g_lhs(cm))->name);
    }
}

bool _manifold_modifier(const W* w){
    switch(w->cls){
        case T_EFFECT:
        case T_CACHE:
        case T_CHECK:
        case T_OPEN:
        case T_PACK:
        case T_PASS:
        case T_FAIL:
        case T_DOC:
            return true;         
        default:
            return false;
    } 
}

void _mod_pathwise(Ws* ws_top, const W* p){
    ws_prmod(ws_top, p, ws_recurse_path, _basename_match, _add_modifier, w_nextval_ifpath);
}

bool _basename_match(const W* w, const W* p){
    bool result = false;
    if(w->cls == C_MANIFOLD){
        Ws* pws = g_ws(g_lhs(p));
        result =
            ws_length(pws) == 1 &&
            label_cmp(g_label(pws->head), g_label(g_lhs(w)));
    }
    return result;
}

// add the modifier stored in p (rhs of couplet) to w
// if:
//   1. the p->lhs contains only one name
//   2. the name matches the name of w
void _add_modifier(const W* w, const W* p){
    if(!p || w->cls != C_MANIFOLD) return;
    Manifold* m = g_manifold(g_rhs(w));
    W* rhs = g_rhs(p);
    switch(p->cls){
        case T_EFFECT:
            m->effect = ws_add_val(m->effect, P_STRING, g_string(rhs));
            break;
        case T_CACHE:
            m->cache = ws_add_val(m->cache, P_STRING, g_string(rhs));
            break;
        case T_CHECK:
            m->check = ws_add_val(m->check, P_STRING, g_string(rhs));
            break;
        case T_OPEN:
            m->open = ws_add_val(m->open, P_STRING, g_string(rhs));
            break;
        case T_PACK:
            m->pack = ws_add_val(m->pack, P_STRING, g_string(rhs));
            break;
        case T_PASS:
            m->pass = ws_add_val(m->pass, P_STRING, g_string(rhs));
            break;
        case T_FAIL:
            m->fail = ws_add_val(m->fail, P_STRING, g_string(rhs));
            break;
        case T_DOC:
            m->doc = ws_add_val(m->doc, P_STRING, g_string(rhs));
            break;
        default:
            break;
            fprintf(
                stderr, "Illegal p (%s) in %s:%d\n",
                w_class_str(p->cls), __func__, __LINE__
            );
    }
}

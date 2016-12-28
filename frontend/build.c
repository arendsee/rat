#include "build.h"

// link all top level elements in c_{i+1} as inputs to c_i
void link_inputs(Table* t_top){
    Table* t_path = table_recursive_get_type(t_top, T_PATH);
    t_path = table_join(t_path, table_recursive_get_type(t_top, C_NEST));
    for(Entry* e_path = t_path->head; e_path; e_path = e_path->next){
        for(Entry* e_com = e_path->value.table->head; e_com; e_com = e_com->next){
            Table* outputs = table_composon_outputs(e_com->next);

            if(!outputs) continue;

            Table* inputs = table_composon_inputs(e_com);
            for(Entry* o = outputs->head; o; o = o->next){
                for(Entry* i = inputs->head; i; i = i->next){
                    i->value.manifold->inputs = table_add(i->value.manifold->inputs, o);
                }
            }
        }
    }
}

/* Mouse has only one couplet type: EFFECT. Rat has a bunch. So the switch
 * statements will be more populous. This function does the following: 
 *  1. Find all couplets of the given type
 *  2. For each couplet:
 *  3.   Find all manifolds in its path
 *  4.   For each manifold couple the given element
 */
void link_couplets(Table* t_top, TType type){
    Table* t_couplet = table_recursive_get_type(t_top, type);
    if(t_couplet && t_couplet->head){
        for(Entry* e = t_couplet->head; e; e = e->next){
            Table* t_man = NULL;
            switch(type){
                case T_EFFECT:
                    t_man = table_selection_get(t_top, e->value.effect->selection, C_MANIFOLD);
                    break;
                default:
                    fprintf(stderr, "ILLEGAL TYPE\n");
                    exit(EXIT_FAILURE);
            }
            if(!t_man){
                continue;
            }
            for(Entry* ee = t_man->head; ee; ee = ee->next){
                Manifold* m = ee->value.manifold;
                switch(type){
                    case T_EFFECT:
                        m->effect = e->value.effect->function;
                        break;
                    default:
                        fprintf(stderr, "ILLEGAL TYPE\n");
                        exit(EXIT_FAILURE);
                }
            }
        }
    }
}

/* Requires input of both a global and current table. The global one is the top
 * level symbol table where all paths should be searched without recursion. The
 * current table is where group references should be sought.*/
bool resolve_grprefs_r(Table* global, Table* current){
    Table* t_ref = table_recursive_get_type(current, C_GRPREF);

    if(!t_ref) return false;

    for(Entry* e_ref = t_ref->head; e_ref; e_ref = e_ref->next){
        Id* id = id_new();
        id->name = strdup(e_ref->value.string);
        Table* t_path = table_get(global, id, T_PATH);
        if(!t_path){
            fprintf(stderr, "ERROR: path '%s', not found\n", id->name);
        }
        if(t_path->head->next){
            fprintf(stderr, "ERROR: Ambiguous path, using first\n");
        }
        Table* resolved = table_clone(t_path->head->value.table);
        if(resolved){
            e_ref->type = T_PATH;
            e_ref->value.table = resolved;
            resolve_grprefs_r(global, resolved);
        } else {
            fprintf(stderr, "ERROR: group reference '%s' could not be resolved\n", id->name);
        }
    }

    return true;
}

void resolve_grprefs(Table* t_top){
    resolve_grprefs_r(t_top, t_top);
}

void build_manifolds(Table* t_top){
    resolve_grprefs(t_top);
    link_inputs(t_top);
    link_couplets(t_top, T_EFFECT);
}
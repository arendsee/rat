#ifndef __WS_H__
#define __WS_H__

#include <stdlib.h>
#include <string.h>

#include "w.h"

typedef struct Ws{
    W* head;
    W* tail;
} Ws;

/* Copies entry and removes its link */
Ws* ws_new(const W* w);

/* Clone ws calling clone on each element. Elements with uid fields will have
 * unique uids, all pointers will be to new objects. Any changes to the clone,
 * any of its elements or sub-elements, will not affect the original.
 */
Ws* ws_clone(const Ws* ws);
// clone the value of a W, this will recurse into and Ws
void w_clone_value(W* w);

/* If ws is NULL, this will create a new Ws.  This basically renders ws_new
 * unnecessary, although I keep it around for symmetry. Also, I do not allow
 * empty Ws. Having this default constructor take an element argument will
 * prevent me from coming in later ad breaking everything by added a empty
 * default constructor.
 */
Ws* ws_add(Ws* ws, const W* w);

Ws* ws_add_val(Ws* ws, Class cls, void* v);

/* b is destroyed upon join */
Ws* ws_join(Ws* a, Ws* b);

/* Make a new table that with the first element dropped */
Ws* ws_increment(const Ws* ws);

int ws_length(const Ws* ws);

void ws_print(const Ws* ws, Ws*(*recurse)(const W*));

char* w_str(const W* w);

// --- algorithms ---

Ws* ws_composon_inputs(W* w);

Ws* ws_composon_outputs(W* w);

#endif

#!/bin/awk -f 

BEGIN {

    FS="\t"

    printf("m4_define(`OUTDIR', %s)", dir) >> rules

    seps["sh"] = " "    
    seps["R"] = ", "

    binds["sh"] = " "
    binds["R"] = "="

    ands["sh"] = "&&"
    ands["R"] = "&&"

    printf("m4_define(`SEP', `%s') ", seps[lang])   >> rules
    printf("m4_define(`BIND', `%s') ", binds[lang]) >> rules
    printf("m4_define(`AND', `%s') ", ands[lang])   >> rules
}

$1 == "EMIT"  { m[$2]["lang"]      = $3 ; next }
$1 == "CACHE" { m[$2]["cache"]     = $3 ; next }
$1 == "CHECK" { m[$2]["check"][$3] = 1  ; next }
$1 == "FUNC"  { m[$2]["func"]      = $3 ; next }
$1 == "PASS"  { m[$2]["pass"]      = $3 ; next }
$1 == "FAIL"  { m[$2]["fail"]      = $3 ; next }
$1 == "PACK"  { m[$2]["pack"]      = $3 ; next }
$1 == "OPEN"  { m[$2]["open"]      = $3 ; next }
$1 == "EFCT"  { m[$2]["efct"][$3]  = 1  ; next }
$1 == "HOOK"  { m[$2]["hook"][$3]  = 1  ; next }
$1 == "INPM"  { m[$2]["m"][$3]     = $4 ; next }
$1 == "INPP"  { m[$2]["p"][$3]     = $4 ; next }

$1 == "ARG" {
    if($4 != "") { arg = $3 " BIND " $4 } else { arg = $3 }
    m[$2]["arg"][arg] = 1
    next
}

END{

    printf "PROLOGUE " >> body
    printf "m4_include(%s)", src >> body

    for(i in m){

        printf "MANIFOLD_%s ", i >> body

        if(m[i]["lang"] == lang){
            printf "m4_define(`MANIFOLD_%s', NATIVE_MANIFOLD(%s)) ", i, i >> rules
        } else if(m[i]["lang"] == "*"){
            printf "m4_define(`MANIFOLD_%s', UNIVERSAL_MANIFOLD(%s)) ", i, i >> rules
        } else {
            printf "m4_define(`MANIFOLD_%s', FOREIGN_MANIFOLD(%s,%s)) ", i, m[i]["lang"], i >> rules
        }

        if(m[i]["cache"]){
            cache = m[i]["cache"]
            printf "m4_define(`BASECACHE_%s', %s)", i, cache >> rules
            printf "m4_define(`CACHE_%s', DO_CACHE(%s))", i, i >> rules
            printf "m4_define(`CACHE_PUT_%s', DO_PUT(%s))", i, i >> rules
        } else {
            printf "m4_define(`CACHE_%s', NO_CACHE(%s))", i, i >> rules
            printf "m4_define(`CACHE_PUT_%s', NO_PUT(%s))", i, i >> rules
        }

        if(length(m[i]["check"]) > 0){
            printf "m4_define(`VALIDATE_%s', DO_VALIDATE(%s)) ", i, i >> rules
            check=""
            for(k in m[i]["check"]){
                check = sprintf("%s AND CHECK(%s)", check, k)
            }
            gsub(/^ AND /, "", check) # remove the last sep
            printf "m4_define(`CHECK_%s', %s) ", i, check >> rules
        } else {
            printf "m4_define(`VALIDATE_%s', NO_VALIDATE(%s)) ", i, i >> rules
        }

        if( "m" in m[i] || "p" in m[i] ){
            k=0
            input=""
            while(1) {
                if(m[i]["m"][k]){
                    input = sprintf("%sSEP CALL(%s)", input, m[i]["m"][k])
                }
                else if(m[i]["p"][k]){
                    input = sprintf("%sSEP %s", input, m[i]["p"][k])
                }
                else {
                    break
                }
                k = k + 1
            }
            gsub(/^SEP /, "", input) # remove the last sep
            printf "m4_define(`INPUT_%s', `XXLEFT %s XXRIGHT')", i, input >> rules
        } else {
            printf "m4_define(`INPUT_%s', %s%s)", i, L, R >> rules
        }

        if(length(m[i]["arg"]) > 0){
            arg=""
            for(k in m[i]["arg"]){
                arg = sprintf("%sSEP %s", arg, k)
            }
            gsub(/^SEP /, "", arg) # remove the initial sep
            printf "m4_define(`ARG_%s', `XXLEFT %s XXRIGHT') ", i, arg >> rules
        } else {
            printf "m4_define(`ARG_%s', %s%s) ", i, L, R >> rules
        }

        if(length(m[i]["efct"]) > 0){
            effect=""
            for(k in m[i]["efct"]){
                effect = sprintf("%s EFFECT(%s) ", effect, k)
            }
            printf "m4_define(`EFFECT_%s', %s)", i, effect >> rules
        } else {
            printf "m4_define(`EFFECT_%s', %s%s)", i, L, R >> rules
        }

        if(length(m[i]["hook"]) > 0){
            hook=""
            for(k in m[i]["hook"]){
                hook = sprintf("%s HOOK(%s) ", hook, k)
            }
            printf "m4_define(`HOOK_%s', %s) ", i, hook >> rules
        } else {
            printf "m4_define(`HOOK_%s', %s%s) ", i, L, R >> rules
        }

        if(m[i]["func"]){
            printf "m4_define(`FUNC_%s', %s)", i, m[i]["func"] >> rules
        } else {
            printf "m4_define(`FUNC_%s', NOTHING)", i >> rules
        }

        if(m[i]["pass"]){
            printf "m4_define(`PASS_%s', %s)", i, m[i]["pass"] 
            printf "m4_define(`RUN_%s', DO_PASS(%s))", i, i >> rules
        } else {
            printf "m4_define(`RUN_%s', NO_PASS(%s))", i, i >> rules
        }

        if(m[i]["open"]){
            print "WARNING: `open` is not yet supported" >> "/dev/stderr"
            # printf "m4_define(`OPEN_%s', OPEN(%s)) ", i, i, m[i]["open"] >> rules
        } else {
            # printf "m4_define(`OPEN_%s', %s%s) ", i,L,R >> rules
        }

        if(m[i]["fail"]){
            printf "m4_define(`FAIL_%s', %s)", i, m[i]["fail"] >> rules
        } else {
            printf "m4_define(`FAIL_%s', SIMPLE_FAIL)", i >> rules
        }

        if(m[i]["pack"]){
            printf "m4_define(`PACKFUN_%s', %s)", m[i]["pack"] >> rules
            printf "m4_define(`PACK_%s', DO_PACK(%s))", i >> rules
        } else {
            printf "m4_define(`PACK_%s', NO_PACK)", i >> rules
        }

    }

    printf "EPILOGUE\n" >> body

}

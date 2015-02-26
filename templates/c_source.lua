local name = JSON_NAME

local function rtrim(s)
    local n = #s
    while n > 0 and s:find("^ ", n) do n = n - 1 end
    return s:sub(1, n)
end

local function indent(text)
    return rtrim('    ' .. string.gsub(text, '\n', '\n    '))
end

local function match(x)
    return function(t) return t[x] or t._ end
end

local function get_current_value(prefix, name)
    if prefix then
        return "obj->" .. prefix .. '.' .. name
    else 
        return "obj->" .. name
    end
end

local function get_current_isset(prefix, name)
    if prefix then
        return "obj->" .. prefix .. '.is_set_' .. name
    else 
        return "obj->is_set_" .. name
    end
end

local function get_new_prefix(prefix, name)
    if prefix then
        return prefix .. '.' .. name
    else
        return name
    end
end

local function If(cond)
    return 'if(' .. cond .. ')\n'
end

local function ElseIf(cond)
    return 'else if(' .. cond .. ')\n'
end

local function Else(cond)
    return 'else(' .. cond .. ')\n'
end

local function IfThenElse(cond, IF, ELSE)
    return '(' .. cond .. ') ? (' .. IF .. ') : (' .. ELSE .. ')'
end

local function Switch(var)
    return 'switch(' .. var .. ')\n'
end

local function Case(case, code)
    return 'case ' .. case .. ':\n' .. indent(code)
end

local function CodeBlock(code)
    return "{\n" .. indent(table.concat(code)) .. "}\n"
end

local function Not(code)
    return '!' .. code
end

local function Eq(left, right)
    return '(' .. left .. ') == (' .. right .. ')'
end

local function strncmp(left, right, length)
    return 'strncmp(' .. left .. ', ' .. right .. ', ' .. length .. ')'
end

local function Neq(left, right)
    return '(' .. left .. ') != (' .. right .. ')'
end

local function Goto(mark)
    return 'goto ' .. mark .. ';\n'
end

local function Mark(name)
    return name .. ':\n'
end

local function And(...)
    return '(' .. table.concat({...}, ') && (') .. ')'
end

local function Or(...)
    return '(' .. table.concat({...}, ') || (') .. ')'
end

local function Lt(left, right)
    return '(' .. right .. ') < (' .. left ..')'
end

local function For(init, cond, nxt)
    return 'for(' .. init .. '; ' .. cond .. '; ' .. nxt ..')'
end

local function gen_validate(obj, prefix)
    local res = { }

    while obj do
        if not obj.is_optional then
            res[#res+1] = If(Not(get_current_isset(prefix, obj.name))) ..
                indent(Goto('failure'))
        end

        if(obj.type == 'object') then
            if(obj.is_optional) then
                res[#res+1] = If(get_current_isset(prefix, obj.name)) ..
                    CodeBlock {
                        gen_validate(obj.children, get_new_prefix(prefix, obj.name))
                    }
            else
                res[#res+1] = gen_validate(obj.children, get_new_prefix(prefix, obj.name))
            end
        end

        obj = obj.next
    end

    return table.concat(res)
end

local function gen_unpack(obj, level, prefix)
    local res = { }

    local key = 'key'
    local key_length = 'key_length'
    local value = 'key'
    local value_length = 'key_length'

    while obj do
        res[#res+1] = If(And(
                             Eq(key_length, string.len(obj.name)), 
                             Eq(0, strncmp(key, obj.name, string.len(obj.name)))))
        res[#res+1] = CodeBlock {
            match(obj.type) {
                object = function() return
                    If(Neq('json->type', 'JSON_OBJ_OBJ')) ..
                    CodeBlock {
                        "struct json_obj* tmp_json", level, " = json;\n",
                        For('json = json->children', 'json', 'json = json->next'),
                        CodeBlock {
                            "key = &data[json->key.start];\n",
                            "key_length = json->key.end - json->key.start;\n",
                            "value = &data[json->value.start];\n",
                            "value_length = json->value.end - json->value.start;\n\n",
                            gen_unpack(obj.children, level+1, get_new_prefix(prefix, obj.name))
                        },
                        "json = tmp_json" .. level .. ";\n"
                    }
                end,
                any = function() return
                    If(Lt(0, 'decode_any(&', get_current_value(prefix, obj.name), 'json, value, value_length)')) ..
                        indent(Goto('failure'))
                end,
                ['string'] = function() return
                    If(Neq('json->type', 'JSON_OBJ_STRING')) ..
                        indent(Goto('failure')) ..
                    get_current_value(prefix, obj.name), " = new_string(value, value_length);\n"
                end,
                int = function() return
                    If(Neq('json->type', 'JSON_OBJ_NUMBER')) ..
                        indent(Goto('failure')) ..
                    get_current_value(prefix, obj.name), " = strtoll(value, NULL, 0);\n"
                end,
                real = function() return
                    If(Neq('json->type', 'JSON_OBJ_NUMBER')) ..
                        indent(Goto('failure')) ..
                    get_current_value(prefix, obj.name), " = strtod(value, NULL);\n"
                end,
                bool = function() return
                    If(And(Neq('json->type', 'JSON_OBJ_TRUE'), Neq('json->type', 'JSON_OBJ_FALSE'))) .. 
                        indent(Goto('failure')) ..
                    get_current_value(prefix, obj.name), " = value->type != JSON_OBJ_FALSE;\n"
                end,
                _ = function() return 'ERROR!' end
            } () ..
            get_current_isset(prefix, obj.name) .. " = 1;\n"
        }

        obj = obj.next
    end
    
    return table.concat(res)
end

local function gen_cleanup(obj, prefix)
    local res = { }

    while obj do
        match(obj.type) {
            object = function()
                res[#res+1] = If(get_current_isset(prefix, obj.name)) ..
                    CodeBlock {
                        gen_cleanup(obj.children, get_new_prefix(prefix, name))
                    }
            end,
            string = function()
                res[#res+1] = If(get_current_isset(prefix, obj.name)) ..
                    indent("free(" .. get_current_value(prefix, obj.name) .. ");\n")
            end,
            any = function()
                res[#res+1] = If(And(get_current_isset(prefix, obj.name), 
                                     Eq(get_current_value(prefix, obj.name) .. ".type",
                                        "JSON_OBJ_STRING)"))) ..
                    indent("free(" .. get_current_value(prefix, obj.name) .. ");\n")
            end,
            _ = function() end
        } ()

        obj = obj.next
    end

    return table.concat(res)
end

local output = {
[[#include <stdio.h>
#include <stdlib.h>
#include <string.h>

]],
'#include "', name, '.h"', [[


static inline char* new_string(const char* src, size_t len)
{
    char* dst = malloc(len+1);
    if(!dst)
        return NULL;
    memcpy(dst, src, len);
    dst[len] = 0;
    return dst;
}

static int decode_any(struct json_obj_any* dst, struct json_obj* json,
                      const char* value, size_t value_length)
{
    dst->type = json->type;
    switch(json->type)
    {
    case JSON_OBJ_NULL:
        break;
    case JSON_OBJ_OBJ:
    case JSON_OBJ_ARRAY:
        dst->obj_start = json->value.start;
        dst->obj_end = json->value.end;
        break;
    case JSON_OBJ_NUMBER:
        dst->integer = strtoll(value, NULL, 0);
        dst->real = strtod(value, NULL);
        break;
    case JSON_OBJ_STRING:
        dst->string_ = new_string(value, value_length);
        break;
    case JSON_OBJ_TRUE:
        dst->type = JSON_OBJ_BOOL;
        dst->bool_ = 1;
        break;
    case JSON_OBJ_FALSE:
        dst->type = JSON_OBJ_BOOL;
        dst->bool_ = 0;
        break;
    default:
        break;
    }
    return 0;
}

]],
"void ", name, "_cleanup(struct ", name, "* obj)\n",
    CodeBlock {
        gen_cleanup(JSON_ROOT)
    },
"\n",
"int ", name, "_unpack(struct ", name, [[* obj, const char* data)
{
    memset(obj, 0, sizeof(*obj));
    const char *key, *value;
    size_t key_length, value_length;
    struct json_obj *json, *json_root = json_lexer(data);
    if(!json_root)
        return -1;
    for(json = json_root; json; json = json->next)
    {
        key = &data[json->key.start];
        key_length = json->key.end - json->key.start;
        value = &data[json->value.start];
        value_length = json->value.end - json->value.start;

]], indent(gen_unpack(JSON_ROOT, 2)), [[
    }

]], indent(gen_validate(JSON_ROOT)), [[

    json_obj_free(json_root);
    return 0;

failure:
    json_obj_free(json_root);
    ]], name, [[_cleanup(obj);
    return -1;\n",
}

]]
}

print(table.concat(output))

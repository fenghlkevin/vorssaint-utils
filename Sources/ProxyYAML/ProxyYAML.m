// SPDX-License-Identifier: GPL-3.0-or-later
#import "ProxyYAML.h"
#include "libyaml/yaml.h"

static NSError *failure(NSString *message, NSUInteger line) {
    return [NSError errorWithDomain:@"Vorssaint.ProxyYAML" code:1
        userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"YAML line %lu: %@",(unsigned long)line,message]}];
}
static id readNode(yaml_document_t *doc, int index, NSUInteger depth, NSError **error) {
    yaml_node_t *node=yaml_document_get_node(doc,index);
    if (!node || depth>64) { *error=failure(@"Maximum nesting exceeded",1); return nil; }
    NSString *tag=[NSString stringWithUTF8String:(const char *)node->tag];
    if (![tag hasPrefix:@"tag:yaml.org,2002:"]) { *error=failure(@"Custom tags are not supported",node->start_mark.line+1); return nil; }
    if (node->type==YAML_SCALAR_NODE) {
        NSString *s=[[NSString alloc] initWithBytes:node->data.scalar.value length:node->data.scalar.length encoding:NSUTF8StringEncoding];
        if (!s) { *error=failure(@"Invalid UTF-8",node->start_mark.line+1); return nil; }
        if (node->data.scalar.style==YAML_PLAIN_SCALAR_STYLE) {
            NSString *lower=s.lowercaseString;
            if ([lower isEqual:@"true"]) return @YES;
            if ([lower isEqual:@"false"]) return @NO;
            if ([lower isEqual:@"null"] || [s isEqual:@"~"] || s.length==0) return NSNull.null;
            // JSON numeric grammar only. Do not turn identifiers, IPs or leading-zero short IDs into numbers.
            NSData *candidate=[[NSString stringWithFormat:@"[%@]",s] dataUsingEncoding:NSUTF8StringEncoding];
            id parsed=[NSJSONSerialization JSONObjectWithData:candidate options:0 error:nil];
            if ([parsed isKindOfClass:NSArray.class] && [parsed count]==1 && [parsed[0] isKindOfClass:NSNumber.class]) return parsed[0];
        }
        return s;
    }
    if (node->type==YAML_SEQUENCE_NODE) {
        NSMutableArray *array=[NSMutableArray array];
        for (yaml_node_item_t *i=node->data.sequence.items.start;i<node->data.sequence.items.top;i++) {
            id value=readNode(doc,*i,depth+1,error); if (!value) return nil; [array addObject:value];
        }
        return array;
    }
    if (node->type==YAML_MAPPING_NODE) {
        NSMutableDictionary *map=[NSMutableDictionary dictionary];
        for (yaml_node_pair_t *p=node->data.mapping.pairs.start;p<node->data.mapping.pairs.top;p++) {
            yaml_node_t *key=yaml_document_get_node(doc,p->key);
            if (!key || key->type!=YAML_SCALAR_NODE) { *error=failure(@"Only string mapping keys are supported",node->start_mark.line+1); return nil; }
            NSString *name=[[NSString alloc] initWithBytes:key->data.scalar.value length:key->data.scalar.length encoding:NSUTF8StringEncoding];
            if (!name || map[name] || [name isEqual:@"<<"]) { *error=failure(@"Duplicate or merge key is not supported",key->start_mark.line+1); return nil; }
            id value=readNode(doc,p->value,depth+1,error); if (!value) return nil; map[name]=value;
        }
        return map;
    }
    *error=failure(@"Unsupported node",node->start_mark.line+1); return nil;
}
NSData *VPYAMLToJSON(NSData *data, NSError **outError) {
    NSError *error=nil;
    // Empty NSData may expose a NULL bytes pointer; libyaml asserts on it.
    if (data.length == 0) { if(outError)*outError=failure(@"Configuration is empty",1); return nil; }
    if (data.length>2*1024*1024) { if(outError)*outError=failure(@"File exceeds 2 MiB",1); return nil; }
    yaml_parser_t parser; yaml_event_t event;
    if (!yaml_parser_initialize(&parser)) return nil;
    yaml_parser_set_input_string(&parser,data.bytes,data.length);
    NSUInteger depth=0,count=0,documents=0;
    BOOL end=NO;
    while (!end) {
        if (!yaml_parser_parse(&parser,&event)) { error=failure(@"Invalid YAML syntax",parser.problem_mark.line+1); break; }
        yaml_event_type_t type=event.type;
        if(type==YAML_MAPPING_START_EVENT || type==YAML_SEQUENCE_START_EVENT) depth++;
        if(type==YAML_MAPPING_END_EVENT || type==YAML_SEQUENCE_END_EVENT) depth--;
        if(type==YAML_DOCUMENT_START_EVENT) documents++;
        if(depth>64 || ++count>100000 || documents>1 || type==YAML_ALIAS_EVENT)
            error=failure(@"Aliases, multiple documents or oversized structures are not supported",event.start_mark.line+1);
        end=type==YAML_STREAM_END_EVENT;
        yaml_event_delete(&event);
        if(error)break;
    }
    yaml_parser_delete(&parser);
    if(error){if(outError)*outError=error;return nil;}
    if(!yaml_parser_initialize(&parser))return nil;
    yaml_parser_set_input_string(&parser,data.bytes,data.length);
    yaml_document_t doc;
    if(!yaml_parser_load(&parser,&doc)) { if(outError)*outError=failure(@"Invalid YAML document",parser.problem_mark.line+1);yaml_parser_delete(&parser);return nil; }
    id object=readNode(&doc,1,0,&error);
    NSData *result=nil;
    if(object && [object isKindOfClass:NSDictionary.class])result=[NSJSONSerialization dataWithJSONObject:object options:NSJSONWritingSortedKeys error:&error];
    else if(!error)error=failure(@"Root must be a mapping",1);
    yaml_document_delete(&doc);yaml_parser_delete(&parser);
    if(error && outError)*outError=error;
    return result;
}

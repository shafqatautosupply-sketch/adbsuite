#include "../src/spake2.h"
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
static const uint8_t C[]="adb pair client",S[]="adb pair server";
static size_t unhex(const char*h,uint8_t*o){size_t n=0;for(;h[0]&&h[1]&&h[0]!='\n';h+=2){unsigned x;sscanf(h,"%2x",&x);o[n++]=x;}return n;}
static void pr(const char*t,const uint8_t*p,size_t n){printf("%s ",t);for(size_t i=0;i<n;i++)printf("%02x",p[i]);printf("\n");fflush(stdout);}
int main(int argc,char**argv){
 int alice=!strcmp(argv[1],"alice");uint8_t pw[512];size_t pl=unhex(argv[2],pw);
 spake2_ctx*c=spake2_new(alice?SPAKE2_ALICE:SPAKE2_BOB,alice?C:S,16,alice?S:C,16);
 uint8_t msg[32],key[64],their[64];
 if(!spake2_generate(c,msg,pw,pl))return 2; pr("MSG",msg,32);
 char line[256]; if(!fgets(line,sizeof line,stdin))return 3;
 size_t tl=unhex(line,their);
 if(!spake2_process(c,key,their,tl)){printf("KEY FAIL\n");return 0;}
 pr("KEY",key,64);return 0;}

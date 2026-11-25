#include "../core/adbapi.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <pthread.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#define CHECK(c) do{ if(!(c)){ char e[500]; adbapi_last_error(e,sizeof e); printf("FAIL line %d: %s  [%s]\n",__LINE__,#c,e); fails++; } else printf("ok   %s\n",#c);}while(0)
static int fails;
static char sess[4096]; static int sess_exit=-1; static pthread_mutex_t mu=PTHREAD_MUTEX_INITIALIZER;
static void scb(int k,const uint8_t*d,size_t n,void*u){ (void)u; pthread_mutex_lock(&mu); if(k==3) sess_exit=d[0]; else strncat(sess,(const char*)d,n); pthread_mutex_unlock(&mu);}
static void* runner(void*a){ adbapi_stream_run((adbapi_stream*)a); return NULL; }
static uint64_t last_done;
static void prog(uint64_t d,uint64_t t,void*u){(void)t;(void)u;last_done=d;}
int main(int argc,char**argv){
  const char*host="127.0.0.1"; int port=atoi(argv[1]);
  adbapi_init("/tmp/suitehome");
  char banner[512]; CHECK(adbapi_probe(host,port,banner,sizeof banner)==0); printf("     banner=%s\n",banner);
  char*out; size_t n; int code;
  CHECK(adbapi_shell(host,port,"echo hello",&out,&n,&code)==0 && strstr(out,"ran: echo hello") && code==0); free(out);
  CHECK(adbapi_shell(host,port,"fail now",&out,&n,&code)==0 && code==1); free(out);
  uint8_t*b; CHECK(adbapi_service(host,port,"exec:screencap -p",&b,&n)==0 && n==strlen("EXEC:screencap -p") && !memcmp(b,"EXEC:",5)); free(b);
  /* session */
  adbapi_stream*s=adbapi_stream_new(host,port,"shell,v2,raw:",1,scb,NULL);
  pthread_t th; pthread_create(&th,NULL,runner,s);
  usleep(400000); adbapi_stream_send(s,"ls\n",3); usleep(300000); adbapi_stream_send(s,"pwd\n",4); usleep(300000);
  adbapi_stream_stop(s); pthread_join(th,NULL); adbapi_stream_free(s);
  CHECK(strstr(sess,"got:ls\n") && strstr(sess,"got:pwd\n"));
  /* push/pull */
  FILE*f=fopen("/tmp/suite_in.bin","wb"); for(int i=0;i<300000;i++) fputc(i*7,f); fclose(f);
  CHECK(adbapi_push(host,port,"/tmp/suite_in.bin","/sdcard/t.bin",prog,NULL)==0 && last_done==300000);
  CHECK(adbapi_pull(host,port,"/sdcard/t.bin","/tmp/suite_out.bin",300000,prog,NULL)==0 && last_done==300000);
  CHECK(system("cmp /tmp/suite_in.bin /tmp/suite_out.bin")==0);
  /* forward */
  adbapi_fwd*fw=adbapi_forward_start(host,port,45999,"tcp:8080",0); CHECK(fw!=NULL);
  int fd=socket(AF_INET,SOCK_STREAM,0); struct sockaddr_in a={0}; a.sin_family=AF_INET;a.sin_port=htons(45999);a.sin_addr.s_addr=htonl(INADDR_LOOPBACK);
  CHECK(connect(fd,(struct sockaddr*)&a,sizeof a)==0);
  write(fd,"ping-through-adb",16); char rb[64]={0}; int got=0; for(int i=0;i<30&&got<16;i++){ int r=recv(fd,rb+got,16-got,MSG_DONTWAIT); if(r>0)got+=r; else usleep(100000);} 
  CHECK(got==16 && !strcmp(rb,"ping-through-adb")); close(fd);
  adbapi_forward_stop(fw);
  char pk[1100]; CHECK(adbapi_pubkey(pk,sizeof pk)==0 && strlen(pk)>600);
  printf(fails?"FAILURES: %d\n":"ALL OK\n",fails); return fails;
}

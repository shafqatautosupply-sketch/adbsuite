// Mock adbd built on BoringSSL: modes "pair PORT CODE" and "adb PORT"
#include <openssl/ssl.h>
#include <openssl/x509.h>
#include <openssl/evp.h>
#include <openssl/ec_key.h>
#include <openssl/curve25519.h>
#include <openssl/hkdf.h>
#include <openssl/aead.h>
#include <openssl/rsa.h>
#include <openssl/bn.h>
#include <openssl/obj.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <unistd.h>
#include <stdio.h>
#include <string.h>
#include <vector>
#include <string>
#include <map>
typedef std::vector<uint8_t> B;
static int g_fd=-1;
static bool rd(int fd,SSL*s,void*b,size_t n){fd=g_fd;uint8_t*p=(uint8_t*)b;while(n){int r=s?SSL_read(s,p,n):read(fd,p,n);if(r<=0)return false;p+=r;n-=r;}return true;}
static bool wr(int fd,SSL*s,const void*b,size_t n){fd=g_fd;const uint8_t*p=(const uint8_t*)b;while(n){int r=s?SSL_write(s,p,n):write(fd,p,n);if(r<=0)return false;p+=r;n-=r;}return true;}
static enum ssl_verify_result_t vcb(SSL*,uint8_t*){return ssl_verify_ok;}
static SSL_CTX* mkctx(){
  SSL_CTX*c=SSL_CTX_new(TLS_method());
  SSL_CTX_set_min_proto_version(c,TLS1_3_VERSION);SSL_CTX_set_max_proto_version(c,TLS1_3_VERSION);
  EVP_PKEY*pk=EVP_PKEY_new();RSA*r=RSA_new();BIGNUM*e=BN_new();BN_set_word(e,65537);RSA_generate_key_ex(r,2048,e,NULL);EVP_PKEY_assign_RSA(pk,r);
  X509*x=X509_new();X509_set_version(x,2);ASN1_INTEGER_set(X509_get_serialNumber(x),1);
  X509_gmtime_adj(X509_getm_notBefore(x),0);X509_gmtime_adj(X509_getm_notAfter(x),1000000);
  X509_set_pubkey(x,pk);X509_NAME*nm=X509_get_subject_name(x);
  X509_NAME_add_entry_by_txt(nm,"CN",MBSTRING_ASC,(const unsigned char*)"mock",-1,-1,0);X509_set_issuer_name(x,nm);
  X509_sign(x,pk,EVP_sha256());
  SSL_CTX_use_certificate(c,x);SSL_CTX_use_PrivateKey(c,pk);
  SSL_CTX_set_custom_verify(c,SSL_VERIFY_PEER,vcb);
  return c;}
static int lis(int port){int s=socket(AF_INET,SOCK_STREAM,0);int o=1;setsockopt(s,SOL_SOCKET,SO_REUSEADDR,&o,4);
  sockaddr_in a{};a.sin_family=AF_INET;a.sin_port=htons(port);a.sin_addr.s_addr=htonl(INADDR_LOOPBACK);
  bind(s,(sockaddr*)&a,sizeof a);listen(s,4);return s;}
static bool pkt_rd(SSL*s,int type,B&out){uint8_t h[6];if(!rd(0,s,h,6))return false;
  uint32_t n=(h[2]<<24)|(h[3]<<16)|(h[4]<<8)|h[5];if(h[0]!=1||h[1]!=type)return fprintf(stderr,"bad hdr %d %d\n",h[0],h[1]),false;
  out.resize(n);return rd(0,s,out.data(),n);}
static bool pkt_wr(SSL*s,int type,const B&d){uint8_t h[6]={1,(uint8_t)type,(uint8_t)(d.size()>>24),(uint8_t)(d.size()>>16),(uint8_t)(d.size()>>8),(uint8_t)d.size()};
  return wr(0,s,h,6)&&wr(0,s,d.data(),d.size());}
static void nonce(uint64_t q,uint8_t*iv){memset(iv,0,12);for(int i=0;i<8;i++)iv[i]=q>>(8*i);}
static int do_pair(int port,const char*code){
  int ls=lis(port);int fd=accept(ls,0,0);g_fd=fd;SSL_CTX*c=mkctx();SSL*s=SSL_new(c);SSL_set_fd(s,fd);
  if(SSL_accept(s)!=1){fprintf(stderr,"mock: TLS accept failed\n");return 1;}
  uint8_t ex[64];if(!SSL_export_keying_material(s,ex,64,"adb-label",10,NULL,0,0)){fprintf(stderr,"export fail\n");return 1;}
  std::string pw(code);pw.append((char*)ex,64);
  SPAKE2_CTX*sp=SPAKE2_CTX_new(spake2_role_bob,(const uint8_t*)"adb pair server",16,(const uint8_t*)"adb pair client",16);
  uint8_t msg[32];size_t ml;SPAKE2_generate_msg(sp,msg,&ml,32,(const uint8_t*)pw.data(),pw.size());
  B their;if(!pkt_rd(s,0,their))return 1;
  if(!pkt_wr(s,0,B(msg,msg+32)))return 1;
  uint8_t key[64];size_t kl;if(!SPAKE2_process_msg(sp,key,&kl,64,their.data(),their.size())){fprintf(stderr,"spake process fail\n");return 1;}
  uint8_t aes[16];HKDF(aes,16,EVP_sha256(),key,kl,NULL,0,(const uint8_t*)"adb pairing_auth aes-128-gcm key",32);
  EVP_AEAD_CTX a;EVP_AEAD_CTX_init(&a,EVP_aead_aes_128_gcm(),aes,16,16,NULL);
  B ct;if(!pkt_rd(s,1,ct))return 1;
  uint8_t iv[12];nonce(0,iv);B pt(ct.size());size_t pl;
  if(!EVP_AEAD_CTX_open(&a,pt.data(),&pl,pt.size(),iv,12,ct.data(),ct.size(),NULL,0)){fprintf(stderr,"mock: DECRYPT FAIL (wrong code)\n");return 1;}
  printf("MOCK_PEERINFO type=%d len=%zu key=%.40s...\n",pt[0],pl,(char*)&pt[1]);fflush(stdout);
  B mine(8192,0);mine[0]=1;strcpy((char*)&mine[1],"mock-guid-1234");
  nonce(0,iv);B ect(8192+16);size_t el;EVP_AEAD_CTX_seal(&a,ect.data(),&el,ect.size(),iv,12,mine.data(),mine.size(),NULL,0);ect.resize(el);
  pkt_wr(s,1,ect);SSL_shutdown(s);return 0;}
// ---- adb mode
struct H{uint32_t c,a0,a1,n,ck,m;};
static bool send_m(SSL*s,uint32_t c,uint32_t a0,uint32_t a1,const void*d,size_t n){H h{c,a0,a1,(uint32_t)n,0,c^0xffffffffu};
  return wr(0,s,&h,24)&&(!n||wr(0,s,d,n));}
static bool recv_m(SSL*s,H&h,B&d){if(!rd(0,s,&h,24))return false;d.resize(h.n);return !h.n||rd(0,s,d.data(),h.n);}
#define C(x) (*(uint32_t*)x)

static bool v2(SSL*s,uint32_t loc,uint32_t rem,int id,const std::string&x){B b(5+x.size());b[0]=id;uint32_t n=x.size();memcpy(&b[1],&n,4);memcpy(&b[5],x.data(),x.size());return send_m(s,0x45545257,loc,rem,b.data(),b.size());}
static std::map<std::string,B> g_files;
static int handle(int fd){
  g_fd=fd;H h;B d;
  if(!recv_m(NULL,h,d)||h.c!=0x4e584e43){fprintf(stderr,"mock: no CNXN\n");return 1;}
  send_m(NULL,0x534c5453,0x01000000,0,NULL,0);
  if(!recv_m(NULL,h,d)||h.c!=0x534c5453){fprintf(stderr,"mock: no STLS\n");return 1;}
  SSL_CTX*c=mkctx();SSL*s=SSL_new(c);SSL_set_fd(s,fd);
  if(SSL_accept(s)!=1){fprintf(stderr,"mock: TLS accept failed\n");return 1;}
  printf("MOCK_TLS_OK peercert=%d\n",SSL_get_peer_certificate(s)!=NULL);fflush(stdout);
  const char*bn="device::ro.product.model=Mock;features=shell_v2,cmd,stat_v2";
  send_m(s,0x4e584e43,0x01000001,1048576,bn,strlen(bn)+1);
  std::string cur;uint32_t rem=7;std::string sbuf;int mode=0; // 1 sync, 2 session, 3 echo
  while(recv_m(s,h,d)){
    if(h.c==0x4e45504f){
      std::string svc((char*)d.data());uint32_t loc=h.a0;send_m(s,0x59414b4f,rem,loc,NULL,0);
      if(svc.rfind("shell,v2,raw:",0)==0){std::string cmd=svc.substr(13);
        if(cmd.empty()){mode=2;}
        else{v2(s,rem,loc,1,"ran: "+cmd+"\n");v2(s,rem,loc,3,std::string(1,(char)(cmd.find("fail")!=std::string::npos?1:0)));send_m(s,0x45534c43,rem,loc,NULL,0);}}
      else if(svc=="sync:"){mode=1;sbuf.clear();}
      else if(svc.rfind("exec:",0)==0){std::string r="EXEC:"+svc.substr(5);send_m(s,0x45545257,rem,loc,r.data(),r.size());send_m(s,0x45534c43,rem,loc,NULL,0);}
      else if(svc.rfind("tcp:",0)==0){mode=3;}
      else {send_m(s,0x45534c43,rem,loc,NULL,0);}
    } else if(h.c==0x45545257){
      send_m(s,0x59414b4f,rem,h.a0,NULL,0);
      if(mode==3){send_m(s,0x45545257,rem,h.a0,d.data(),d.size());}
      else if(mode==2){ // framed stdin packets
        size_t o=0;while(o+5<=d.size()){uint32_t n;memcpy(&n,&d[o+1],4);int id=d[o];
          if(id==0)v2(s,rem,h.a0,1,"got:"+std::string((char*)&d[o+5],n));
          else if(id==3){v2(s,rem,h.a0,3,std::string(1,(char)0));send_m(s,0x45534c43,rem,h.a0,NULL,0);}
          o+=5+n;}}
      else if(mode==1){sbuf.append((char*)d.data(),d.size());
        for(;;){ if(sbuf.size()<8)break; std::string id=sbuf.substr(0,4);uint32_t n;memcpy(&n,&sbuf[4],4);
          if(id=="SEND"){ if(sbuf.size()<8+n)break; cur=sbuf.substr(8,n);cur=cur.substr(0,cur.rfind(','));g_files[cur].clear();sbuf.erase(0,8+n);}
          else if(id=="DATA"){ if(sbuf.size()<8+n)break; g_files[cur].insert(g_files[cur].end(),sbuf.begin()+8,sbuf.begin()+8+n);sbuf.erase(0,8+n);}
          else if(id=="DONE"){ sbuf.erase(0,8);char r[8]={'O','K','A','Y',0,0,0,0};send_m(s,0x45545257,rem,h.a0,r,8);printf("MOCK_PUSHED %s %zu\n",cur.c_str(),g_files[cur].size());fflush(stdout);}
          else if(id=="RECV"){ if(sbuf.size()<8+n)break; std::string p=sbuf.substr(8,n);sbuf.erase(0,8+n);
            B&f=g_files[p];size_t off=0;while(off<f.size()){size_t k=std::min<size_t>(f.size()-off,65536);B o(8+k);memcpy(&o[0],"DATA",4);uint32_t kk=k;memcpy(&o[4],&kk,4);memcpy(&o[8],&f[off],k);send_m(s,0x45545257,rem,h.a0,o.data(),o.size());off+=k;}
            char dn[8]={'D','O','N','E',0,0,0,0};send_m(s,0x45545257,rem,h.a0,dn,8);}
          else {fprintf(stderr,"mock: bad sync id\n");break;}
        }}
    } else if(h.c==0x45534c43){send_m(s,0x45534c43,rem,h.a0,NULL,0);break;}
  }
  SSL_free(s);SSL_CTX_free(c);close(fd);return 0;}
static int do_adb(int port){int ls=lis(port);for(;;){int fd=accept(ls,0,0);if(fd<0)break;handle(fd);}return 0;}
#include <signal.h>
int main(int argc,char**argv){signal(SIGPIPE,SIG_IGN);
  if(!strcmp(argv[1],"pair"))return do_pair(atoi(argv[2]),argv[3]);
  if(!strcmp(argv[1],"adb"))return do_adb(atoi(argv[2]));
  return 2;}

// BoringSSL reference peer: spake_ref <alice|bob> <password-hex>
#include <openssl/curve25519.h>
#include <stdio.h>
#include <string.h>
#include <string>
#include <vector>
static const uint8_t C[] = "adb pair client", S[] = "adb pair server";
static std::string hex(const uint8_t*p,size_t n){std::string s;char b[3];for(size_t i=0;i<n;i++){snprintf(b,3,"%02x",p[i]);s+=b;}return s;}
static std::vector<uint8_t> unhex(const char*h){std::vector<uint8_t> v;for(size_t i=0;h[i]&&h[i+1]&&h[i]!='\n';i+=2){unsigned x;sscanf(h+i,"%2x",&x);v.push_back(x);}return v;}
int main(int argc,char**argv){
  bool alice=!strcmp(argv[1],"alice"); auto pw=unhex(argv[2]);
  SPAKE2_CTX*c=SPAKE2_CTX_new(alice?spake2_role_alice:spake2_role_bob,
     alice?C:S,16, alice?S:C,16);
  uint8_t msg[32];size_t n=0;
  if(!SPAKE2_generate_msg(c,msg,&n,32,pw.data(),pw.size()))return 2;
  printf("MSG %s\n",hex(msg,n).c_str());fflush(stdout);
  char line[256]; if(!fgets(line,sizeof line,stdin))return 3;
  auto their=unhex(line); uint8_t key[64];size_t kl=0;
  if(!SPAKE2_process_msg(c,key,&kl,64,their.data(),their.size())){printf("KEY FAIL\n");return 0;}
  printf("KEY %s\n",hex(key,kl).c_str());return 0;}

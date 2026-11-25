import subprocess, os, sys
def run(a_cmd,b_cmd):
    a=subprocess.Popen(a_cmd,stdin=subprocess.PIPE,stdout=subprocess.PIPE,text=True)
    b=subprocess.Popen(b_cmd,stdin=subprocess.PIPE,stdout=subprocess.PIPE,text=True)
    am=a.stdout.readline().split()[1]; bm=b.stdout.readline().split()[1]
    a.stdin.write(bm+"\n");a.stdin.flush();b.stdin.write(am+"\n");b.stdin.flush()
    ak=a.stdout.readline().strip(); bk=b.stdout.readline().strip()
    a.wait();b.wait(); return ak,bk
ref,mine=sys.argv[1],sys.argv[2]
bad=0
for i in range(30):
    pw=os.urandom(6+i%5).hex()+os.urandom(64).hex()
    for mine_alice in (True,False):
        A=[mine,"alice",pw] if mine_alice else [ref,"alice",pw]
        B=[ref,"bob",pw] if mine_alice else [mine,"bob",pw]
        ak,bk=run(A,B)
        if ak!=bk or "FAIL" in ak: bad+=1; print("MISMATCH",i,mine_alice,ak[:20],bk[:20])
# negative: different passwords must differ
ak,bk=run([mine,"alice","aa11"],[ref,"bob","bb22"])
print("neg differs:",ak!=bk)
print("failures:",bad)

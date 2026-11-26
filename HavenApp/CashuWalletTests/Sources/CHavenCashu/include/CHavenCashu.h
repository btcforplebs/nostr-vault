// The three Cashu wallet exports of libhaven (haven-go/cashu_wallet_cshared.go),
// for the test package only. The app gets them from the generated libhaven.h.
#ifndef CHAVEN_CASHU_H
#define CHAVEN_CASHU_H

extern char* CashuWalletOpenC(char* path);
extern char* CashuWalletCallC(int handle, char* method, char* args);
extern void CashuWalletCloseC(int handle);

#endif

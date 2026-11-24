#ifndef RUNNER_WINRT_P2P_CORE_H_
#define RUNNER_WINRT_P2P_CORE_H_

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct WinRtP2pStatus {
  bool supported;
  bool wifi_enabled;
  bool bluetooth_enabled;
  bool is_group_active;
  char ssid[64];
  char passphrase[64];
  char go_ip[32];
} WinRtP2pStatus;

typedef struct WinRtP2pHotspotResult {
  bool success;
  char ssid[64];
  char passphrase[64];
  char go_ip[32];
  int port;
  char error[160];
} WinRtP2pHotspotResult;

typedef struct WinRtP2pConnectResult {
  bool success;
  char go_ip[32];
  char error[160];
} WinRtP2pConnectResult;

typedef struct WinRtP2pDiscoveredPeer {
  char id[48];
  char name[64];
  int port;
  char device_type[16];
  char ssid[64];
  char passphrase[64];
  char go_ip[32];
  char air_token[32];
} WinRtP2pDiscoveredPeer;

typedef void (*WinRtP2pPeerFoundFn)(const WinRtP2pDiscoveredPeer* peer,
                                    void* user_data);
typedef void (*WinRtP2pHotspotStoppedFn)(void* user_data);

void WinRtP2p_Initialize(WinRtP2pPeerFoundFn on_peer_found,
                         WinRtP2pHotspotStoppedFn on_hotspot_stopped,
                         void* user_data);

void WinRtP2p_Shutdown(void);

void WinRtP2p_GetStatus(WinRtP2pStatus* out_status);

void WinRtP2p_StartAdvertising(const char* device_id,
                               const char* device_name,
                               int port,
                               const char* air_token,
                               WinRtP2pHotspotResult* out_result);

void WinRtP2p_StopAdvertising(void);

bool WinRtP2p_StartDiscovery(bool is_passive);

void WinRtP2p_SetDiscoveryPace(bool is_passive);

void WinRtP2p_StopDiscovery(void);

void WinRtP2p_ConnectToPeer(const char* ssid,
                            const char* passphrase,
                            const char* fallback_go_ip,
                            int port,
                            WinRtP2pConnectResult* out_result);

void WinRtP2p_DisconnectDirect(void);

#ifdef __cplusplus
}
#endif

#endif  // RUNNER_WINRT_P2P_CORE_H_

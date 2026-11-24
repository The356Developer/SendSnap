#include "winrt_p2p_core.h"

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif

#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <iphlpapi.h>
#include <wlanapi.h>

#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Devices.Bluetooth.h>
#include <winrt/Windows.Devices.Bluetooth.Advertisement.h>
#include <winrt/Windows.Devices.Enumeration.h>
#include <winrt/Windows.Devices.WiFiDirect.h>
#include <winrt/Windows.Security.Credentials.h>
#include <winrt/Windows.Storage.Streams.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cctype>
#include <cstdio>
#include <cstring>
#include <map>
#include <mutex>
#include <random>
#include <string>
#include <thread>
#include <vector>

namespace {

using winrt::Windows::Devices::Bluetooth::BluetoothAdapter;
using winrt::Windows::Devices::Bluetooth::Advertisement::BluetoothLEAdvertisementDataSection;
using winrt::Windows::Devices::Bluetooth::Advertisement::BluetoothLEAdvertisementPublisher;
using winrt::Windows::Devices::Bluetooth::Advertisement::BluetoothLEAdvertisementPublisherStatus;
using winrt::Windows::Devices::Bluetooth::Advertisement::BluetoothLEAdvertisementReceivedEventArgs;
using winrt::Windows::Devices::Bluetooth::Advertisement::BluetoothLEAdvertisementWatcher;
using winrt::Windows::Devices::Bluetooth::Advertisement::BluetoothLEManufacturerData;
using winrt::Windows::Devices::Bluetooth::Advertisement::BluetoothLEScanningMode;
using winrt::Windows::Devices::WiFiDirect::WiFiDirectAdvertisementPublisher;
using winrt::Windows::Devices::WiFiDirect::WiFiDirectAdvertisementPublisherStatus;
using winrt::Windows::Devices::WiFiDirect::WiFiDirectConnectionListener;
using winrt::Windows::Devices::WiFiDirect::WiFiDirectConnectionRequestedEventArgs;
using winrt::Windows::Devices::WiFiDirect::WiFiDirectDevice;
using winrt::Windows::Security::Credentials::PasswordCredential;
using winrt::Windows::Storage::Streams::DataReader;
using winrt::Windows::Storage::Streams::DataWriter;

constexpr uint16_t kSendSnapCompanyId = 0x3560;
constexpr uint8_t kFormatCompactV3Android = 0x31;
constexpr uint8_t kFormatCompactV3Windows = 0x32;
constexpr uint8_t kFormatGenericV3Windows = 0x34;
constexpr uint8_t kFormatLegacyCompact01 = 0x01;
constexpr uint8_t kFormatLegacyGeneric02 = 0x02;
constexpr const char* kDirectPrefix = "DIRECT-S5-Snap";
constexpr const char* kDefaultWinGoIp = "192.168.137.1";
constexpr const char* kAlphanum =
    "ABCDEFGHJKLMNPQRSTUVWXYZ23456789abcdefghijkmnopqrstuvwxyz";

struct CachedBleAdv {
  std::vector<uint8_t> adv_fe55;
  std::vector<uint8_t> resp_fe56;
  std::string local_name;
  uint64_t updated_ms = 0;
};

struct CoreState {
  std::mutex mutex;
  WinRtP2pPeerFoundFn on_peer_found = nullptr;
  WinRtP2pHotspotStoppedFn on_hotspot_stopped = nullptr;
  void* callback_user_data = nullptr;

  bool is_advertising = false;
  uint64_t advertising_gen = 0;
  std::string active_ssid;
  std::string active_passphrase;
  std::string active_go_ip;
  int active_port = 53318;

  WiFiDirectAdvertisementPublisher wfd_publisher{nullptr};
  winrt::event_token wfd_status_token{};
  WiFiDirectConnectionListener wfd_listener{nullptr};
  winrt::event_token wfd_conn_token{};
  std::vector<WiFiDirectDevice> connected_wfd_devices;

  BluetoothLEAdvertisementPublisher ble_publisher{nullptr};

  bool is_discovering = false;
  BluetoothLEAdvertisementWatcher ble_watcher{nullptr};
  winrt::event_token ble_received_token{};
  std::map<uint64_t, CachedBleAdv> ble_cache;
  std::map<std::string, uint64_t> last_emitted_ms;

  // Outgoing WLAN direct client state
  GUID connected_wlan_guid{};
  bool has_connected_wlan = false;
  std::wstring temp_profile_name;
  std::wstring previous_profile_name;
};

CoreState& GetState() {
  static CoreState state;
  return state;
}

uint64_t NowMs() {
  return static_cast<uint64_t>(
      std::chrono::duration_cast<std::chrono::milliseconds>(
          std::chrono::steady_clock::now().time_since_epoch())
          .count());
}

void CopyStr(char* dst, size_t dst_size, const std::string& src) {
  if (dst_size == 0) return;
  size_t n = (std::min)(dst_size - 1, src.size());
  if (n > 0) {
    std::memcpy(dst, src.data(), n);
  }
  dst[n] = '\0';
}

std::string RandomAlphanum(size_t len) {
  static thread_local std::mt19937 rng{std::random_device{}()};
  const size_t alphabet_len = std::strlen(kAlphanum);
  std::uniform_int_distribution<size_t> dist(0, alphabet_len - 1);
  std::string out;
  out.reserve(len);
  for (size_t i = 0; i < len; ++i) {
    out.push_back(kAlphanum[dist(rng)]);
  }
  return out;
}

void EnsureWinRtThreadInitialized() {
  try {
    winrt::init_apartment(winrt::apartment_type::multi_threaded);
  } catch (const winrt::hresult_error&) {
    // Already initialized on this thread (e.g. STA on UI thread) — safe to continue.
  }
}

void QueryWlanStatus(bool* out_supported, bool* out_enabled) {
  *out_supported = false;
  *out_enabled = false;

  HANDLE client = nullptr;
  DWORD negotiated = 0;
  if (WlanOpenHandle(2, nullptr, &negotiated, &client) != ERROR_SUCCESS ||
      client == nullptr) {
    return;
  }

  PWLAN_INTERFACE_INFO_LIST list = nullptr;
  if (WlanEnumInterfaces(client, nullptr, &list) == ERROR_SUCCESS &&
      list != nullptr) {
    if (list->dwNumberOfItems > 0) {
      *out_supported = true;
      for (DWORD i = 0; i < list->dwNumberOfItems; ++i) {
        const GUID& guid = list->InterfaceInfo[i].InterfaceGuid;
        DWORD data_size = 0;
        PWLAN_RADIO_STATE radio = nullptr;
        if (WlanQueryInterface(
                client, &guid, wlan_intf_opcode_radio_state, nullptr,
                &data_size, reinterpret_cast<PVOID*>(&radio),
                nullptr) == ERROR_SUCCESS &&
            radio != nullptr) {
          for (DWORD r = 0; r < radio->dwNumberOfPhys; ++r) {
            const auto& phy = radio->PhyRadioState[r];
            if (phy.dot11HardwareRadioState == dot11_radio_state_on &&
                phy.dot11SoftwareRadioState == dot11_radio_state_on) {
              *out_enabled = true;
            }
          }
          WlanFreeMemory(radio);
        } else {
          // Many drivers omit radio_state query when active; treat non-disconnected or present interface as enabled.
          *out_enabled = true;
        }
      }
    }
    WlanFreeMemory(list);
  }

  WlanCloseHandle(client, nullptr);
}

bool IsBluetoothAvailable() {
  try {
    EnsureWinRtThreadInitialized();
    auto op = BluetoothAdapter::GetDefaultAsync();
    if (op.wait_for(std::chrono::milliseconds(500)) ==
        winrt::Windows::Foundation::AsyncStatus::Completed) {
      auto adapter = op.GetResults();
      return adapter != nullptr && adapter.IsLowEnergySupported();
    }
  } catch (...) {
  }
  return false;
}

std::string FindDirectSoftApIpv4() {
  ULONG buf_len = 32768;
  std::vector<uint8_t> buffer(buf_len);
  auto* addresses = reinterpret_cast<PIP_ADAPTER_ADDRESSES>(buffer.data());

  DWORD rc = GetAdaptersAddresses(
      AF_INET, GAA_FLAG_SKIP_ANYCAST | GAA_FLAG_SKIP_MULTICAST | GAA_FLAG_SKIP_DNS_SERVER,
      nullptr, addresses, &buf_len);
  if (rc == ERROR_BUFFER_OVERFLOW) {
    buffer.resize(buf_len);
    addresses = reinterpret_cast<PIP_ADAPTER_ADDRESSES>(buffer.data());
    rc = GetAdaptersAddresses(
        AF_INET, GAA_FLAG_SKIP_ANYCAST | GAA_FLAG_SKIP_MULTICAST | GAA_FLAG_SKIP_DNS_SERVER,
        nullptr, addresses, &buf_len);
  }
  if (rc != NO_ERROR) return "";

  std::string fallback_137;
  for (PIP_ADAPTER_ADDRESSES cur = addresses; cur != nullptr; cur = cur->Next) {
    if (cur->OperStatus != IfOperStatusUp) continue;

    std::wstring friendly = cur->FriendlyName ? cur->FriendlyName : L"";
    std::wstring desc = cur->Description ? cur->Description : L"";
    std::wstring lower_friendly = friendly;
    std::wstring lower_desc = desc;
    std::transform(lower_friendly.begin(), lower_friendly.end(),
                   lower_friendly.begin(), ::towlower);
    std::transform(lower_desc.begin(), lower_desc.end(), lower_desc.begin(),
                   ::towlower);

    const bool is_wfd_adapter =
        lower_friendly.find(L"local area connection*") != std::wstring::npos ||
        lower_desc.find(L"wi-fi direct") != std::wstring::npos ||
        lower_desc.find(L"hosted network") != std::wstring::npos;

    for (PIP_ADAPTER_UNICAST_ADDRESS ua = cur->FirstUnicastAddress;
         ua != nullptr; ua = ua->Next) {
      if (ua->Address.lpSockaddr == nullptr ||
          ua->Address.lpSockaddr->sa_family != AF_INET) {
        continue;
      }
      auto* sin = reinterpret_cast<sockaddr_in*>(ua->Address.lpSockaddr);
      char ip_buf[INET_ADDRSTRLEN] = {};
      if (inet_ntop(AF_INET, &sin->sin_addr, ip_buf, sizeof(ip_buf)) == nullptr) {
        continue;
      }
      std::string ip(ip_buf);
      if (ip.rfind("127.", 0) == 0 || ip.rfind("169.254.", 0) == 0 ||
          ip == "0.0.0.0") {
        continue;
      }
      if (is_wfd_adapter) {
        return ip;
      }
      if (ip.rfind("192.168.137.", 0) == 0) {
        fallback_137 = ip;
      }
    }
  }
  return fallback_137;
}

void ParseDeviceId6Bytes(const std::string& device_id, uint8_t out_bytes[6]) {
  std::string hex;
  hex.reserve(12);
  for (char c : device_id) {
    char lc = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
    if ((lc >= '0' && lc <= '9') || (lc >= 'a' && lc <= 'f')) {
      hex.push_back(lc);
      if (hex.size() == 12) break;
    }
  }
  while (hex.size() < 12) hex.push_back('0');

  auto hex_val = [](char c) -> uint8_t {
    if (c >= '0' && c <= '9') return static_cast<uint8_t>(c - '0');
    if (c >= 'a' && c <= 'f') return static_cast<uint8_t>(10 + (c - 'a'));
    return 0;
  };
  for (int i = 0; i < 6; ++i) {
    out_bytes[i] = static_cast<uint8_t>((hex_val(hex[i * 2]) << 4) |
                                        hex_val(hex[i * 2 + 1]));
  }
}

std::string BytesToHex(const uint8_t* data, size_t len) {
  static const char* kHex = "0123456789abcdef";
  std::string out;
  out.reserve(len * 2);
  for (size_t i = 0; i < len; ++i) {
    out.push_back(kHex[(data[i] >> 4) & 0x0F]);
    out.push_back(kHex[data[i] & 0x0F]);
  }
  return out;
}

void ParseIpLastTwoOctets(const std::string& ip, uint8_t* o3, uint8_t* o4) {
  int a = 0, b = 0, c = 137, d = 1;
  if (sscanf_s(ip.c_str(), "%d.%d.%d.%d", &a, &b, &c, &d) == 4) {
    *o3 = static_cast<uint8_t>(std::clamp(c, 0, 255));
    *o4 = static_cast<uint8_t>(std::clamp(d, 0, 255));
  } else {
    *o3 = 137;
    *o4 = 1;
  }
}

void StartBleBeaconLocked(CoreState& state,
                          const std::string& device_id,
                          int port,
                          const std::string& ssid,
                          const std::string& pass,
                          const std::string& go_ip) {
  try {
    if (state.ble_publisher != nullptr) {
      try {
        state.ble_publisher.Stop();
      } catch (...) {
      }
      state.ble_publisher = nullptr;
    }

    uint8_t o3 = 137, o4 = 1;
    ParseIpLastTwoOctets(go_ip, &o3, &o4);
    uint8_t id6[6] = {};
    ParseDeviceId6Bytes(device_id, id6);

    std::vector<uint8_t> payload;
    const size_t prefix_len = std::strlen(kDirectPrefix);
    if (ssid.rfind(kDirectPrefix, 0) == 0 && ssid.size() == prefix_len + 4 &&
        pass.size() == 8) {
      // 23-byte single-frame ManufacturerData (CompanyId 0x3560):
      // [0]=0x32 (v3 Windows), [1..4]=suffix, [5..12]=pass, [13..14]=port,
      // [15..16]=o3,o4, [17..22]=id6
      payload.resize(23);
      payload[0] = kFormatCompactV3Windows;
      std::memcpy(&payload[1], ssid.data() + prefix_len, 4);
      std::memcpy(&payload[5], pass.data(), 8);
      payload[13] = static_cast<uint8_t>((port >> 8) & 0xFF);
      payload[14] = static_cast<uint8_t>(port & 0xFF);
      payload[15] = o3;
      payload[16] = o4;
      std::memcpy(&payload[17], id6, 6);
    } else if (ssid.size() <= 11 && pass.size() == 8) {
      // Compact generic fallback if driver modified SSID prefix (max 24 bytes)
      payload.resize(13 + ssid.size());
      payload[0] = kFormatGenericV3Windows;
      payload[1] = static_cast<uint8_t>(ssid.size());
      std::memcpy(&payload[2], ssid.data(), ssid.size());
      size_t off = 2 + ssid.size();
      std::memcpy(&payload[off], pass.data(), 8);
      payload[off + 8] = static_cast<uint8_t>((port >> 8) & 0xFF);
      payload[off + 9] = static_cast<uint8_t>(port & 0xFF);
      payload[off + 10] = o3;
      payload[off + 11] = o4;
    } else {
      return;
    }

    DataWriter writer;
    writer.WriteBytes(winrt::array_view<const uint8_t>(payload));
    BluetoothLEManufacturerData mfg(kSendSnapCompanyId, writer.DetachBuffer());

    BluetoothLEAdvertisementPublisher pub;
    pub.Advertisement().ManufacturerData().Append(mfg);
    pub.Start();
    state.ble_publisher = pub;
  } catch (...) {
    // Bluetooth off or unsupported on desktop — Wi-Fi Direct + QR still active.
    state.ble_publisher = nullptr;
  }
}

void StopAdvertisingLocked(CoreState& state) {
  state.advertising_gen++;
  state.is_advertising = false;
  state.active_ssid.clear();
  state.active_passphrase.clear();
  state.active_go_ip.clear();

  if (state.ble_publisher != nullptr) {
    try {
      state.ble_publisher.Stop();
    } catch (...) {
    }
    state.ble_publisher = nullptr;
  }

  if (state.wfd_listener != nullptr) {
    try {
      state.wfd_listener.ConnectionRequested(state.wfd_conn_token);
    } catch (...) {
    }
    state.wfd_listener = nullptr;
  }

  for (auto& dev : state.connected_wfd_devices) {
    try {
      dev.Close();
    } catch (...) {
    }
  }
  state.connected_wfd_devices.clear();

  if (state.wfd_publisher != nullptr) {
    try {
      state.wfd_publisher.StatusChanged(state.wfd_status_token);
    } catch (...) {
    }
    try {
      state.wfd_publisher.Stop();
    } catch (...) {
    }
    state.wfd_publisher = nullptr;
  }
}

std::vector<uint8_t> ReadBufferBytes(
    const winrt::Windows::Storage::Streams::IBuffer& buf) {
  if (buf == nullptr || buf.Length() == 0) return {};
  std::vector<uint8_t> out(buf.Length());
  auto reader = DataReader::FromBuffer(buf);
  reader.ReadBytes(winrt::array_view<uint8_t>(out));
  return out;
}

void EmitDiscoveredPeer(CoreState& state, const WinRtP2pDiscoveredPeer& peer) {
  WinRtP2pPeerFoundFn cb = nullptr;
  void* ud = nullptr;
  {
    std::lock_guard<std::mutex> lock(state.mutex);
    if (!state.is_discovering || state.on_peer_found == nullptr) return;
    const uint64_t now = NowMs();
    auto it = state.last_emitted_ms.find(peer.id);
    if (it != state.last_emitted_ms.end() && (now - it->second) < 2500) {
      return;
    }
    state.last_emitted_ms[peer.id] = now;
    cb = state.on_peer_found;
    ud = state.callback_user_data;
  }
  if (cb != nullptr) {
    cb(&peer, ud);
  }
}

bool DecodeMfgPayload(const std::vector<uint8_t>& data,
                      const std::string& fallback_name,
                      WinRtP2pDiscoveredPeer* out_peer) {
  if (data.empty()) return false;
  const uint8_t tag = data[0];

  if ((tag == kFormatCompactV3Android || tag == kFormatCompactV3Windows) &&
      data.size() >= 23) {
    std::string suffix(reinterpret_cast<const char*>(&data[1]), 4);
    std::string pass(reinterpret_cast<const char*>(&data[5]), 8);
    int port = ((static_cast<int>(data[13]) & 0xFF) << 8) |
               (static_cast<int>(data[14]) & 0xFF);
    if (port <= 0) return false;
    int o3 = static_cast<int>(data[15]) & 0xFF;
    int o4 = static_cast<int>(data[16]) & 0xFF;
    std::string hex12 = BytesToHex(&data[17], 6);

    std::string ssid = std::string(kDirectPrefix) + suffix;
    std::string go_ip =
        "192.168." + std::to_string(o3) + "." + std::to_string(o4);
    const char* dev_type =
        (tag == kFormatCompactV3Windows) ? "windows" : "android";
    std::string name = !fallback_name.empty()
                           ? fallback_name
                           : (tag == kFormatCompactV3Windows ? "Windows PC"
                                                             : "SendSnap Device");

    std::memset(out_peer, 0, sizeof(*out_peer));
    CopyStr(out_peer->id, sizeof(out_peer->id), "ble-" + hex12);
    CopyStr(out_peer->name, sizeof(out_peer->name), name);
    out_peer->port = port;
    CopyStr(out_peer->device_type, sizeof(out_peer->device_type), dev_type);
    CopyStr(out_peer->ssid, sizeof(out_peer->ssid), ssid);
    CopyStr(out_peer->passphrase, sizeof(out_peer->passphrase), pass);
    CopyStr(out_peer->go_ip, sizeof(out_peer->go_ip), go_ip);
    return true;
  }

  if (tag == kFormatGenericV3Windows && data.size() >= 14) {
    size_t ssid_len = data[1];
    if (ssid_len == 0 || ssid_len > 16 || data.size() < 2 + ssid_len + 12) {
      return false;
    }
    std::string ssid(reinterpret_cast<const char*>(&data[2]), ssid_len);
    size_t off = 2 + ssid_len;
    std::string pass(reinterpret_cast<const char*>(&data[off]), 8);
    int port = ((static_cast<int>(data[off + 8]) & 0xFF) << 8) |
               (static_cast<int>(data[off + 9]) & 0xFF);
    int o3 = static_cast<int>(data[off + 10]) & 0xFF;
    int o4 = static_cast<int>(data[off + 11]) & 0xFF;
    std::string go_ip =
        "192.168." + std::to_string(o3) + "." + std::to_string(o4);

    std::memset(out_peer, 0, sizeof(*out_peer));
    CopyStr(out_peer->id, sizeof(out_peer->id), "ble-" + ssid);
    CopyStr(out_peer->name, sizeof(out_peer->name),
            !fallback_name.empty() ? fallback_name : "Windows PC");
    out_peer->port = port > 0 ? port : 53318;
    CopyStr(out_peer->device_type, sizeof(out_peer->device_type), "windows");
    CopyStr(out_peer->ssid, sizeof(out_peer->ssid), ssid);
    CopyStr(out_peer->passphrase, sizeof(out_peer->passphrase), pass);
    CopyStr(out_peer->go_ip, sizeof(out_peer->go_ip), go_ip);
    return true;
  }

  return false;
}

bool DecodeServiceDataPair(const std::vector<uint8_t>& adv,
                           const std::vector<uint8_t>& resp,
                           WinRtP2pDiscoveredPeer* out_peer) {
  if (adv.empty()) return false;
  if (adv[0] == kFormatLegacyCompact01 && adv.size() >= 21) {
    std::string suffix(reinterpret_cast<const char*>(&adv[1]), 4);
    std::string pass(reinterpret_cast<const char*>(&adv[5]), 8);
    int port = ((static_cast<int>(adv[13]) & 0xFF) << 8) |
               (static_cast<int>(adv[14]) & 0xFF);
    if (port <= 0) return false;
    std::string hex12 = BytesToHex(&adv[15], 6);
    std::string name = "SendSnap Device";
    if (resp.size() > 1 && resp[0] == kFormatLegacyCompact01) {
      std::string decoded(reinterpret_cast<const char*>(&resp[1]),
                          resp.size() - 1);
      if (!decoded.empty()) name = decoded;
    }

    std::memset(out_peer, 0, sizeof(*out_peer));
    CopyStr(out_peer->id, sizeof(out_peer->id), "ble-" + hex12);
    CopyStr(out_peer->name, sizeof(out_peer->name), name);
    out_peer->port = port;
    CopyStr(out_peer->device_type, sizeof(out_peer->device_type), "android");
    CopyStr(out_peer->ssid, sizeof(out_peer->ssid),
            std::string(kDirectPrefix) + suffix);
    CopyStr(out_peer->passphrase, sizeof(out_peer->passphrase), pass);
    CopyStr(out_peer->go_ip, sizeof(out_peer->go_ip), "192.168.49.1");
    return true;
  }

  if (adv[0] == kFormatLegacyGeneric02 && adv.size() >= 6 &&
      resp.size() >= 8 && resp[0] == kFormatLegacyGeneric02) {
    int port = ((static_cast<int>(adv[1]) & 0xFF) << 8) |
               (static_cast<int>(adv[2]) & 0xFF);
    int o3 = static_cast<int>(adv[3]) & 0xFF;
    int o4 = static_cast<int>(adv[4]) & 0xFF;
    size_t ssid_len = adv[5] & 0xFF;
    if (port <= 0 || ssid_len == 0 || ssid_len > 18 ||
        adv.size() < 6 + ssid_len) {
      return false;
    }
    std::string ssid(reinterpret_cast<const char*>(&adv[6]), ssid_len);
    std::string hex12 = BytesToHex(&resp[1], 6);
    size_t pass_len = resp[7] & 0xFF;
    if (pass_len == 0 || pass_len > 19 || resp.size() < 8 + pass_len) {
      return false;
    }
    std::string pass(reinterpret_cast<const char*>(&resp[8]), pass_len);
    std::string go_ip =
        "192.168." + std::to_string(o3) + "." + std::to_string(o4);

    std::memset(out_peer, 0, sizeof(*out_peer));
    CopyStr(out_peer->id, sizeof(out_peer->id), "ble-" + hex12);
    CopyStr(out_peer->name, sizeof(out_peer->name), "SendSnap Device");
    out_peer->port = port;
    CopyStr(out_peer->device_type, sizeof(out_peer->device_type), "android");
    CopyStr(out_peer->ssid, sizeof(out_peer->ssid), ssid);
    CopyStr(out_peer->passphrase, sizeof(out_peer->passphrase), pass);
    CopyStr(out_peer->go_ip, sizeof(out_peer->go_ip), go_ip);
    return true;
  }

  return false;
}

void HandleBleReceived(const BluetoothLEAdvertisementReceivedEventArgs& args) {
  auto& state = GetState();
  try {
    const uint64_t addr = args.BluetoothAddress();
    const auto adv = args.Advertisement();
    std::string local_name = winrt::to_string(adv.LocalName());

    // 1. Check ManufacturerData (CompanyId 0x3560)
    for (const auto& mfg : adv.ManufacturerData()) {
      if (mfg.CompanyId() == kSendSnapCompanyId) {
        auto bytes = ReadBufferBytes(mfg.Data());
        WinRtP2pDiscoveredPeer peer{};
        if (DecodeMfgPayload(bytes, local_name, &peer)) {
          EmitDiscoveredPeer(state, peer);
          return;
        }
      }
    }

    // 2. Check 16-bit Service Data (0x16) for UUIDs 0xFE55 / 0xFE56 from Android
    bool touched = false;
    WinRtP2pDiscoveredPeer decoded_peer{};
    bool has_decoded = false;

    {
      std::lock_guard<std::mutex> lock(state.mutex);
      for (const auto& sec : adv.DataSections()) {
        if (sec.DataType() != 0x16) continue;
        auto bytes = ReadBufferBytes(sec.Data());
        if (bytes.size() < 3) continue;
        const uint16_t uuid16 = static_cast<uint16_t>(bytes[0]) |
                                (static_cast<uint16_t>(bytes[1]) << 8);
        if (uuid16 == 0xFE55) {
          auto& entry = state.ble_cache[addr];
          entry.adv_fe55.assign(bytes.begin() + 2, bytes.end());
          entry.updated_ms = NowMs();
          touched = true;
        } else if (uuid16 == 0xFE56) {
          auto& entry = state.ble_cache[addr];
          entry.resp_fe56.assign(bytes.begin() + 2, bytes.end());
          entry.updated_ms = NowMs();
          touched = true;
        }
      }

      if (touched) {
        const auto& entry = state.ble_cache[addr];
        if (!entry.adv_fe55.empty()) {
          has_decoded = DecodeServiceDataPair(entry.adv_fe55, entry.resp_fe56,
                                              &decoded_peer);
        }
      }
    }

    if (has_decoded) {
      EmitDiscoveredPeer(state, decoded_peer);
    }
  } catch (...) {
  }
}

std::wstring EscapeXml(const std::string& input) {
  std::wstring out;
  for (unsigned char c : input) {
    switch (c) {
      case '&':
        out += L"&amp;";
        break;
      case '<':
        out += L"&lt;";
        break;
      case '>':
        out += L"&gt;";
        break;
      case '"':
        out += L"&quot;";
        break;
      case '\'':
        out += L"&apos;";
        break;
      default:
        out.push_back(static_cast<wchar_t>(c));
        break;
    }
  }
  return out;
}

bool VerifyTcpPort(const std::string& ip, int port, int timeout_ms) {
  if (ip.empty() || port <= 0) return false;
  SOCKET sock = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
  if (sock == INVALID_SOCKET) return false;

  u_long non_blocking = 1;
  ioctlsocket(sock, FIONBIO, &non_blocking);

  sockaddr_in addr{};
  addr.sin_family = AF_INET;
  addr.sin_port = htons(static_cast<u_short>(port));
  if (inet_pton(AF_INET, ip.c_str(), &addr.sin_addr) != 1) {
    closesocket(sock);
    return false;
  }

  connect(sock, reinterpret_cast<sockaddr*>(&addr), sizeof(addr));

  fd_set write_fds;
  FD_ZERO(&write_fds);
  FD_SET(sock, &write_fds);

  timeval tv{};
  tv.tv_sec = timeout_ms / 1000;
  tv.tv_usec = (timeout_ms % 1000) * 1000;

  bool ok = false;
  if (select(0, nullptr, &write_fds, nullptr, &tv) > 0 &&
      FD_ISSET(sock, &write_fds)) {
    int so_error = 0;
    int len = sizeof(so_error);
    if (getsockopt(sock, SOL_SOCKET, SO_ERROR,
                   reinterpret_cast<char*>(&so_error), &len) == 0 &&
        so_error == 0) {
      ok = true;
    }
  }

  closesocket(sock);
  return ok;
}

std::string FindGatewayForInterfaceGuid(const GUID& target_guid) {
  ULONG buf_len = 32768;
  std::vector<uint8_t> buffer(buf_len);
  auto* addresses = reinterpret_cast<PIP_ADAPTER_ADDRESSES>(buffer.data());

  DWORD rc = GetAdaptersAddresses(AF_INET, GAA_FLAG_INCLUDE_GATEWAYS, nullptr,
                                  addresses, &buf_len);
  if (rc == ERROR_BUFFER_OVERFLOW) {
    buffer.resize(buf_len);
    addresses = reinterpret_cast<PIP_ADAPTER_ADDRESSES>(buffer.data());
    rc = GetAdaptersAddresses(AF_INET, GAA_FLAG_INCLUDE_GATEWAYS, nullptr,
                              addresses, &buf_len);
  }
  if (rc != NO_ERROR) return "";

  char target_guid_str[64] = {};
  std::snprintf(
      target_guid_str, sizeof(target_guid_str),
      "{%08lX-%04X-%04X-%02X%02X-%02X%02X%02X%02X%02X%02X}", target_guid.Data1,
      target_guid.Data2, target_guid.Data3, target_guid.Data4[0],
      target_guid.Data4[1], target_guid.Data4[2], target_guid.Data4[3],
      target_guid.Data4[4], target_guid.Data4[5], target_guid.Data4[6],
      target_guid.Data4[7]);

  for (PIP_ADAPTER_ADDRESSES cur = addresses; cur != nullptr; cur = cur->Next) {
    if (cur->AdapterName == nullptr ||
        _stricmp(cur->AdapterName, target_guid_str) != 0) {
      continue;
    }
    if (cur->OperStatus != IfOperStatusUp) continue;

    bool has_valid_ipv4 = false;
    std::string derived_gw;
    for (PIP_ADAPTER_UNICAST_ADDRESS ua = cur->FirstUnicastAddress;
         ua != nullptr; ua = ua->Next) {
      if (ua->Address.lpSockaddr == nullptr ||
          ua->Address.lpSockaddr->sa_family != AF_INET) {
        continue;
      }
      auto* sin = reinterpret_cast<sockaddr_in*>(ua->Address.lpSockaddr);
      char ip_buf[INET_ADDRSTRLEN] = {};
      if (inet_ntop(AF_INET, &sin->sin_addr, ip_buf, sizeof(ip_buf)) ==
          nullptr) {
        continue;
      }
      std::string ip(ip_buf);
      if (ip.rfind("169.254.", 0) == 0 || ip == "0.0.0.0") continue;
      has_valid_ipv4 = true;
      int a = 0, b = 0, c = 0, d = 0;
      if (sscanf_s(ip.c_str(), "%d.%d.%d.%d", &a, &b, &c, &d) == 4) {
        derived_gw = std::to_string(a) + "." + std::to_string(b) + "." +
                     std::to_string(c) + ".1";
      }
    }
    if (!has_valid_ipv4) return "";

    for (PIP_ADAPTER_GATEWAY_ADDRESS_LH gw = cur->FirstGatewayAddress;
         gw != nullptr; gw = gw->Next) {
      if (gw->Address.lpSockaddr == nullptr ||
          gw->Address.lpSockaddr->sa_family != AF_INET) {
        continue;
      }
      auto* sin = reinterpret_cast<sockaddr_in*>(gw->Address.lpSockaddr);
      char gw_buf[INET_ADDRSTRLEN] = {};
      if (inet_ntop(AF_INET, &sin->sin_addr, gw_buf, sizeof(gw_buf)) !=
          nullptr) {
        std::string g(gw_buf);
        if (!g.empty() && g != "0.0.0.0") return g;
      }
    }
    return derived_gw;
  }
  return "";
}

}  // namespace

extern "C" {

void WinRtP2p_Initialize(WinRtP2pPeerFoundFn on_peer_found,
                         WinRtP2pHotspotStoppedFn on_hotspot_stopped,
                         void* user_data) {
  WSADATA wsa{};
  WSAStartup(MAKEWORD(2, 2), &wsa);

  auto& state = GetState();
  std::lock_guard<std::mutex> lock(state.mutex);
  state.on_peer_found = on_peer_found;
  state.on_hotspot_stopped = on_hotspot_stopped;
  state.callback_user_data = user_data;
}

void WinRtP2p_Shutdown(void) {
  WinRtP2p_StopDiscovery();
  WinRtP2p_StopAdvertising();
  WinRtP2p_DisconnectDirect();

  auto& state = GetState();
  std::lock_guard<std::mutex> lock(state.mutex);
  state.on_peer_found = nullptr;
  state.on_hotspot_stopped = nullptr;
  state.callback_user_data = nullptr;
}

void WinRtP2p_GetStatus(WinRtP2pStatus* out_status) {
  if (out_status == nullptr) return;
  std::memset(out_status, 0, sizeof(*out_status));

  bool supported = false;
  bool wifi_enabled = false;
  QueryWlanStatus(&supported, &wifi_enabled);

  out_status->supported = supported;
  out_status->wifi_enabled = wifi_enabled;
  out_status->bluetooth_enabled = IsBluetoothAvailable();

  auto& state = GetState();
  std::lock_guard<std::mutex> lock(state.mutex);
  out_status->is_group_active =
      state.is_advertising && !state.active_ssid.empty();
  CopyStr(out_status->ssid, sizeof(out_status->ssid), state.active_ssid);
  CopyStr(out_status->passphrase, sizeof(out_status->passphrase),
          state.active_passphrase);
  CopyStr(out_status->go_ip, sizeof(out_status->go_ip), state.active_go_ip);
}

void WinRtP2p_StartAdvertising(const char* device_id,
                               const char* /*device_name*/,
                               int port,
                               const char* /*air_token*/,
                               WinRtP2pHotspotResult* out_result) {
  if (out_result == nullptr) return;
  std::memset(out_result, 0, sizeof(*out_result));
  out_result->port = port > 0 ? port : 53318;

  EnsureWinRtThreadInitialized();

  bool supported = false;
  bool wifi_enabled = false;
  QueryWlanStatus(&supported, &wifi_enabled);
  if (!supported || !wifi_enabled) {
    CopyStr(out_result->error, sizeof(out_result->error),
            "Wi-Fi adapter is turned off or unavailable on this PC");
    return;
  }

  auto& state = GetState();
  uint64_t my_gen = 0;
  std::string requested_ssid = std::string(kDirectPrefix) + RandomAlphanum(4);
  std::string requested_pass = RandomAlphanum(8);
  std::string dev_id_str = device_id ? device_id : "";

  try {
    WiFiDirectAdvertisementPublisher pub;
    pub.Advertisement().IsAutonomousGroupOwnerEnabled(true);
    pub.Advertisement().LegacySettings().IsEnabled(true);
    pub.Advertisement().LegacySettings().Ssid(
        winrt::to_hstring(requested_ssid));

    PasswordCredential cred;
    cred.Password(winrt::to_hstring(requested_pass));
    pub.Advertisement().LegacySettings().Passphrase(cred);

    WiFiDirectConnectionListener listener;
    auto conn_token = listener.ConnectionRequested(
        [](const WiFiDirectConnectionListener&,
           const WiFiDirectConnectionRequestedEventArgs& args) {
          try {
            EnsureWinRtThreadInitialized();
            auto req = args.GetConnectionRequest();
            auto op =
                WiFiDirectDevice::FromIdAsync(req.DeviceInformation().Id());
            if (op.wait_for(std::chrono::seconds(5)) ==
                winrt::Windows::Foundation::AsyncStatus::Completed) {
              auto dev = op.GetResults();
              if (dev != nullptr) {
                auto& st = GetState();
                std::lock_guard<std::mutex> lock(st.mutex);
                if (st.is_advertising) {
                  st.connected_wfd_devices.push_back(dev);
                } else {
                  dev.Close();
                }
              }
            }
          } catch (...) {
          }
        });

    {
      std::lock_guard<std::mutex> lock(state.mutex);
      StopAdvertisingLocked(state);
      my_gen = ++state.advertising_gen;
      state.is_advertising = true;
      state.active_port = out_result->port;
      state.wfd_publisher = pub;
      state.wfd_listener = listener;
      state.wfd_conn_token = conn_token;
      state.wfd_status_token = pub.StatusChanged(
          [my_gen](const WiFiDirectAdvertisementPublisher& sender,
                   const auto& args) {
            if (args.Status() ==
                WiFiDirectAdvertisementPublisherStatus::Aborted) {
              WinRtP2pHotspotStoppedFn stopped_cb = nullptr;
              void* ud = nullptr;
              {
                auto& st = GetState();
                std::lock_guard<std::mutex> lk(st.mutex);
                if (st.advertising_gen == my_gen && st.is_advertising) {
                  st.is_advertising = false;
                  st.active_ssid.clear();
                  st.active_passphrase.clear();
                  st.active_go_ip.clear();
                  stopped_cb = st.on_hotspot_stopped;
                  ud = st.callback_user_data;
                }
              }
              if (stopped_cb != nullptr) {
                stopped_cb(ud);
              }
            }
            (void)sender;
          });
    }

    pub.Start();

    // Poll up to 3.0s for Started + soft-AP IPv4 assignment (typically ~1.0s)
    bool started = false;
    std::string resolved_ip;
    for (int i = 0; i < 20; ++i) {
      auto st = pub.Status();
      if (st == WiFiDirectAdvertisementPublisherStatus::Aborted ||
          st == WiFiDirectAdvertisementPublisherStatus::Stopped) {
        if (i >= 2) break;
      }
      if (st == WiFiDirectAdvertisementPublisherStatus::Started) {
        started = true;
        resolved_ip = FindDirectSoftApIpv4();
        if (!resolved_ip.empty()) {
          break;
        }
      }
      std::this_thread::sleep_for(std::chrono::milliseconds(150));
    }

    if (!started) {
      std::lock_guard<std::mutex> lock(state.mutex);
      if (state.advertising_gen == my_gen) {
        StopAdvertisingLocked(state);
      }
      CopyStr(out_result->error, sizeof(out_result->error),
              "Windows Wi-Fi Direct hotspot could not start");
      return;
    }

    if (resolved_ip.empty()) {
      resolved_ip = kDefaultWinGoIp;
    }

    std::string actual_ssid = requested_ssid;
    try {
      std::string driver_ssid =
          winrt::to_string(pub.Advertisement().LegacySettings().Ssid());
      if (!driver_ssid.empty()) {
        actual_ssid = driver_ssid;
      }
    } catch (...) {
    }

    {
      std::lock_guard<std::mutex> lock(state.mutex);
      if (state.advertising_gen != my_gen || !state.is_advertising) {
        CopyStr(out_result->error, sizeof(out_result->error), "Cancelled");
        return;
      }
      state.active_ssid = actual_ssid;
      state.active_passphrase = requested_pass;
      state.active_go_ip = resolved_ip;
      StartBleBeaconLocked(state, dev_id_str, out_result->port, actual_ssid,
                           requested_pass, resolved_ip);
    }

    out_result->success = true;
    CopyStr(out_result->ssid, sizeof(out_result->ssid), actual_ssid);
    CopyStr(out_result->passphrase, sizeof(out_result->passphrase),
            requested_pass);
    CopyStr(out_result->go_ip, sizeof(out_result->go_ip), resolved_ip);
  } catch (const winrt::hresult_error& e) {
    std::lock_guard<std::mutex> lock(state.mutex);
    if (state.advertising_gen == my_gen) {
      StopAdvertisingLocked(state);
    }
    CopyStr(out_result->error, sizeof(out_result->error),
            winrt::to_string(e.message()));
  } catch (...) {
    std::lock_guard<std::mutex> lock(state.mutex);
    if (state.advertising_gen == my_gen) {
      StopAdvertisingLocked(state);
    }
    CopyStr(out_result->error, sizeof(out_result->error),
            "Unexpected Windows Wi-Fi Direct error");
  }
}

void WinRtP2p_StopAdvertising(void) {
  EnsureWinRtThreadInitialized();
  auto& state = GetState();
  std::lock_guard<std::mutex> lock(state.mutex);
  StopAdvertisingLocked(state);
}

bool WinRtP2p_StartDiscovery(bool is_passive) {
  EnsureWinRtThreadInitialized();
  auto& state = GetState();
  std::lock_guard<std::mutex> lock(state.mutex);

  try {
    if (state.ble_watcher != nullptr) {
      try {
        state.ble_watcher.Received(state.ble_received_token);
        state.ble_watcher.Stop();
      } catch (...) {
      }
      state.ble_watcher = nullptr;
    }

    state.ble_cache.clear();
    state.last_emitted_ms.clear();

    BluetoothLEAdvertisementWatcher watcher;
    watcher.ScanningMode(is_passive ? BluetoothLEScanningMode::Passive
                                    : BluetoothLEScanningMode::Active);
    state.ble_received_token = watcher.Received(
        [](const BluetoothLEAdvertisementWatcher&,
           const BluetoothLEAdvertisementReceivedEventArgs& args) {
          HandleBleReceived(args);
        });
    watcher.Start();
    state.ble_watcher = watcher;
    state.is_discovering = true;
    return true;
  } catch (...) {
    state.ble_watcher = nullptr;
    state.is_discovering = false;
    return false;
  }
}

void WinRtP2p_SetDiscoveryPace(bool is_passive) {
  auto& state = GetState();
  bool should_restart = false;
  {
    std::lock_guard<std::mutex> lock(state.mutex);
    if (state.is_discovering && state.ble_watcher != nullptr) {
      auto desired = is_passive ? BluetoothLEScanningMode::Passive
                                : BluetoothLEScanningMode::Active;
      if (state.ble_watcher.ScanningMode() != desired) {
        should_restart = true;
      }
    }
  }
  if (should_restart) {
    WinRtP2p_StartDiscovery(is_passive);
  }
}

void WinRtP2p_StopDiscovery(void) {
  EnsureWinRtThreadInitialized();
  auto& state = GetState();
  std::lock_guard<std::mutex> lock(state.mutex);
  state.is_discovering = false;
  state.ble_cache.clear();
  state.last_emitted_ms.clear();
  if (state.ble_watcher != nullptr) {
    try {
      state.ble_watcher.Received(state.ble_received_token);
    } catch (...) {
    }
    try {
      state.ble_watcher.Stop();
    } catch (...) {
    }
    state.ble_watcher = nullptr;
  }
}

void WinRtP2p_ConnectToPeer(const char* ssid,
                            const char* passphrase,
                            const char* fallback_go_ip,
                            int port,
                            WinRtP2pConnectResult* out_result) {
  if (out_result == nullptr) return;
  std::memset(out_result, 0, sizeof(*out_result));

  std::string target_ssid = ssid ? ssid : "";
  std::string target_pass = passphrase ? passphrase : "";
  std::string fallback_ip =
      (fallback_go_ip && fallback_go_ip[0] != '\0') ? fallback_go_ip : "192.168.49.1";
  int target_port = port > 0 ? port : 53318;

  if (target_ssid.empty() || target_pass.size() < 8) {
    CopyStr(out_result->error, sizeof(out_result->error),
            "Missing Direct Wi-Fi SSID or passphrase");
    return;
  }

  HANDLE client = nullptr;
  DWORD negotiated = 0;
  if (WlanOpenHandle(2, nullptr, &negotiated, &client) != ERROR_SUCCESS ||
      client == nullptr) {
    CopyStr(out_result->error, sizeof(out_result->error),
            "Windows WLAN service is unavailable");
    return;
  }

  PWLAN_INTERFACE_INFO_LIST list = nullptr;
  if (WlanEnumInterfaces(client, nullptr, &list) != ERROR_SUCCESS ||
      list == nullptr || list->dwNumberOfItems == 0) {
    if (list) WlanFreeMemory(list);
    WlanCloseHandle(client, nullptr);
    CopyStr(out_result->error, sizeof(out_result->error),
            "No Wi-Fi adapter found on this PC");
    return;
  }

  // Prefer an idle/disconnected Wi-Fi interface; otherwise use primary interface.
  DWORD chosen_idx = 0;
  for (DWORD i = 0; i < list->dwNumberOfItems; ++i) {
    if (list->InterfaceInfo[i].isState != wlan_interface_state_connected) {
      chosen_idx = i;
      break;
    }
  }

  const GUID iface_guid = list->InterfaceInfo[chosen_idx].InterfaceGuid;
  std::wstring prev_profile;
  if (list->InterfaceInfo[chosen_idx].isState ==
      wlan_interface_state_connected) {
    DWORD conn_size = 0;
    PWLAN_CONNECTION_ATTRIBUTES conn_attr = nullptr;
    if (WlanQueryInterface(
            client, &iface_guid, wlan_intf_opcode_current_connection, nullptr,
            &conn_size, reinterpret_cast<PVOID*>(&conn_attr),
            nullptr) == ERROR_SUCCESS &&
        conn_attr != nullptr) {
      if (conn_attr->strProfileName[0] != L'\0') {
        prev_profile = conn_attr->strProfileName;
      }
      WlanFreeMemory(conn_attr);
    }
  }
  WlanFreeMemory(list);

  std::wstring wssid = EscapeXml(target_ssid);
  std::wstring wpass = EscapeXml(target_pass);
  std::wstring profile_name(target_ssid.begin(), target_ssid.end());

  std::wstring xml =
      L"<?xml version=\"1.0\"?>"
      L"<WLANProfile xmlns=\"http://www.microsoft.com/networking/WLAN/profile/v1\">"
      L"<name>" + wssid + L"</name>"
      L"<SSIDConfig><SSID><name>" + wssid + L"</name></SSID></SSIDConfig>"
      L"<connectionType>ESS</connectionType>"
      L"<connectionMode>manual</connectionMode>"
      L"<MSM><security>"
      L"<authEncryption><authentication>WPA2PSK</authentication>"
      L"<encryption>AES</encryption><useOneX>false</useOneX></authEncryption>"
      L"<sharedKey><keyType>passPhrase</keyType><protected>false</protected>"
      L"<keyMaterial>" + wpass + L"</keyMaterial></sharedKey>"
      L"</security></MSM></WLANProfile>";

  DWORD reason_code = 0;
  DWORD set_rc = WlanSetProfile(client, &iface_guid, 0, xml.c_str(), nullptr,
                                TRUE, nullptr, &reason_code);
  if (set_rc != ERROR_SUCCESS) {
    WlanCloseHandle(client, nullptr);
    CopyStr(out_result->error, sizeof(out_result->error),
            "Could not configure temporary Direct Wi-Fi profile");
    return;
  }

  DOT11_SSID dot11_ssid{};
  dot11_ssid.uSSIDLength = static_cast<ULONG>(
      (std::min)(target_ssid.size(), static_cast<size_t>(DOT11_SSID_MAX_LENGTH)));
  std::memcpy(dot11_ssid.ucSSID, target_ssid.data(), dot11_ssid.uSSIDLength);

  WLAN_CONNECTION_PARAMETERS params{};
  params.wlanConnectionMode = wlan_connection_mode_profile;
  params.strProfile = profile_name.c_str();
  params.pDot11Ssid = &dot11_ssid;
  params.dot11BssType = dot11_BSS_type_infrastructure;
  params.dwFlags = 0;

  // Trigger quick scan in case receiver hotspot just started broadcasting
  WlanScan(client, &iface_guid, &dot11_ssid, nullptr, nullptr);
  std::this_thread::sleep_for(std::chrono::milliseconds(350));

  DWORD conn_rc = WlanConnect(client, &iface_guid, &params, nullptr);
  if (conn_rc != ERROR_SUCCESS) {
    WlanDeleteProfile(client, &iface_guid, profile_name.c_str(), nullptr);
    WlanCloseHandle(client, nullptr);
    CopyStr(out_result->error, sizeof(out_result->error),
            "Failed to initiate Direct Wi-Fi connection");
    return;
  }

  {
    auto& state = GetState();
    std::lock_guard<std::mutex> lock(state.mutex);
    state.connected_wlan_guid = iface_guid;
    state.has_connected_wlan = true;
    state.temp_profile_name = profile_name;
    if (prev_profile != profile_name) {
      state.previous_profile_name = prev_profile;
    }
  }

  std::string resolved_gw;
  bool reachable = false;
  for (int i = 0; i < 32; ++i) {
    std::this_thread::sleep_for(std::chrono::milliseconds(300));
    std::string gw = FindGatewayForInterfaceGuid(iface_guid);
    if (!gw.empty()) {
      resolved_gw = gw;
      if (VerifyTcpPort(gw, target_port, 600)) {
        reachable = true;
        break;
      }
      if (gw != fallback_ip && VerifyTcpPort(fallback_ip, target_port, 600)) {
        resolved_gw = fallback_ip;
        reachable = true;
        break;
      }
    }
  }

  WlanCloseHandle(client, nullptr);

  if (reachable || !resolved_gw.empty()) {
    out_result->success = true;
    CopyStr(out_result->go_ip, sizeof(out_result->go_ip),
            resolved_gw.empty() ? fallback_ip : resolved_gw);
  } else {
    WinRtP2p_DisconnectDirect();
    CopyStr(out_result->error, sizeof(out_result->error),
            "Timed out connecting to receiver Direct Wi-Fi hotspot");
  }
}

void WinRtP2p_DisconnectDirect(void) {
  GUID iface_guid{};
  std::wstring temp_prof;
  std::wstring prev_prof;
  bool active = false;

  {
    auto& state = GetState();
    std::lock_guard<std::mutex> lock(state.mutex);
    active = state.has_connected_wlan;
    iface_guid = state.connected_wlan_guid;
    temp_prof = state.temp_profile_name;
    prev_prof = state.previous_profile_name;
    state.has_connected_wlan = false;
    state.temp_profile_name.clear();
    state.previous_profile_name.clear();
  }

  if (!active) return;

  HANDLE client = nullptr;
  DWORD negotiated = 0;
  if (WlanOpenHandle(2, nullptr, &negotiated, &client) != ERROR_SUCCESS ||
      client == nullptr) {
    return;
  }

  WlanDisconnect(client, &iface_guid, nullptr);
  if (!temp_prof.empty()) {
    WlanDeleteProfile(client, &iface_guid, temp_prof.c_str(), nullptr);
  }

  if (!prev_prof.empty()) {
    WLAN_CONNECTION_PARAMETERS params{};
    params.wlanConnectionMode = wlan_connection_mode_profile;
    params.strProfile = prev_prof.c_str();
    params.dot11BssType = dot11_BSS_type_infrastructure;
    WlanConnect(client, &iface_guid, &params, nullptr);
  }

  WlanCloseHandle(client, nullptr);
}

}  // extern "C"

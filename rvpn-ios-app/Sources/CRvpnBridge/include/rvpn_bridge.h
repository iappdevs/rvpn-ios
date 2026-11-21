#ifndef RVPN_BRIDGE_H
#define RVPN_BRIDGE_H

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// Lifecycle
int rvpn_initialize(void);
int rvpn_tun_create(const char *config_json);
int rvpn_tun_start(void);
int rvpn_tun_stop(void);
void rvpn_tun_destroy(void);
int rvpn_tun_get_state(void);

// Info
char *rvpn_tun_get_ip(void);
char *rvpn_tun_get_gateway_ip(void);
int rvpn_tun_get_mtu(void);
char *rvpn_tun_get_server_ip(void);
char *rvpn_tun_get_server_identity(void);
char *rvpn_tun_get_server_identity_for(const char *name);
uint64_t rvpn_tun_get_last_rx_time(void);
int rvpn_tun_check_connectivity(void);

// Packets (TUN mode — called from the NetworkExtension packet provider)
int rvpn_tun_write_packet(const uint8_t *data, uintptr_t len);
int rvpn_tun_write_packet_batch(const uint8_t *data, uintptr_t total_len,
                                 uint32_t *offsets, uint32_t *lengths, uintptr_t count);
int rvpn_tun_read_packet(uint8_t *buffer, uintptr_t buffer_len, uintptr_t *out_len);
int rvpn_tun_wait_for_packet(uint64_t timeout_ms);

// State callback
typedef void (*rvpn_state_callback_t)(int32_t state, const char *ip, const char *msg);
void rvpn_tun_set_state_callback(rvpn_state_callback_t callback);

// Log callback
typedef void (*rvpn_log_callback_t)(int32_t level, const char *msg);
void rvpn_set_log_callback(rvpn_log_callback_t callback);

// Network change
int rvpn_network_changed(int has_internet);

// Identity management
char *rvpn_generate_identity(void);
int rvpn_validate_identity(const char *identity_content);

// Bypass data
char *rvpn_get_bypass_ips_for_countries(const char *country_codes_json, const char *country_ips_file);
char *rvpn_get_bypass_domains_for_countries(const char *country_codes_json, const char *country_domains_file);

// String cleanup
void rvpn_free_string(char *str);

// Error
char *rvpn_last_error(void);

#ifdef __cplusplus
}
#endif

#endif // RVPN_BRIDGE_H

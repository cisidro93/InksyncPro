use mdns_sd::{ServiceDaemon, ServiceInfo};
use std::collections::HashMap;

pub struct DiscoveryManager {
    daemon: ServiceDaemon,
}

impl DiscoveryManager {
    pub fn new() -> Result<Self, mdns_sd::Error> {
        let daemon = ServiceDaemon::new()?;
        Ok(Self { daemon })
    }

    pub fn advertise_calibre(&self, port: u16, hostname: &str) -> Result<(), mdns_sd::Error> {
        let service_type = "_calibrewireless._tcp.local.";
        let instance_name = format!("Inksync Calibre ({})", hostname);
        // Clean hostname for mDNS format
        let clean_host = hostname.replace(" ", "-").to_lowercase();
        let host_name = format!("{}.local.", clean_host);
        
        let mut properties = HashMap::new();
        properties.insert("device_name".to_string(), "Inksync Windows".to_string());
        properties.insert("protocol_version".to_string(), "1".to_string());
        
        let service_info = ServiceInfo::new(
            service_type,
            &instance_name,
            &host_name,
            "127.0.0.1", // standard fallback local mapping
            port,
            Some(properties),
        )?;

        self.daemon.register(service_info)?;
        println!("mDNS: Registered Calibre Wireless Service on port {}", port);
        Ok(())
    }

    pub fn advertise_sync(&self, port: u16, hostname: &str) -> Result<(), mdns_sd::Error> {
        let service_type = "_inksyncdesk._tcp.local.";
        let instance_name = format!("Inksync Sync ({})", hostname);
        let clean_host = hostname.replace(" ", "-").to_lowercase();
        let host_name = format!("{}.local.", clean_host);
        
        let mut properties = HashMap::new();
        properties.insert("version".to_string(), "1.0.0".to_string());
        properties.insert("api_endpoint".to_string(), "/api/v1".to_string());
        
        let service_info = ServiceInfo::new(
            service_type,
            &instance_name,
            &host_name,
            "127.0.0.1",
            port,
            Some(properties),
        )?;

        self.daemon.register(service_info)?;
        println!("mDNS: Registered Inksync Sync Service on port {}", port);
        Ok(())
    }
}

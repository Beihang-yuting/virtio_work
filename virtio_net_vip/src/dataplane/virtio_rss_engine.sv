`ifndef VIRTIO_RSS_ENGINE_SV
`define VIRTIO_RSS_ENGINE_SV

// ============================================================================
// virtio_rss_engine
//
// Receive Side Scaling (RSS) hash computation and queue selection engine.
// Implements Toeplitz hash over packet flow fields {src_ip, dst_ip,
// src_port, dst_port} with configurable hash key and indirection table.
//
// Hash types follow virtio spec:
//   Bit 0: IPv4 (no ports)
//   Bit 1: TCPv4
//   Bit 2: UDPv4
//   Bit 3: IPv6 (no ports)
//   Bit 4: TCPv6
//   Bit 5: UDPv6
//   Bit 6: IPv6 extension (no ports)
//   Bit 7: TCPv6 extension
//   Bit 8: UDPv6 extension
// ============================================================================

class virtio_rss_engine extends uvm_object;
    `uvm_object_utils(virtio_rss_engine)

    // RSS configuration
    int unsigned      hash_key_size = 40;
    byte unsigned     hash_key[];
    int unsigned      indirection_table[];
    bit [31:0]        hash_types;

    // Hash type bit positions
    localparam int unsigned VIRTIO_NET_RSS_HASH_TYPE_IPv4     = 0;
    localparam int unsigned VIRTIO_NET_RSS_HASH_TYPE_TCPv4    = 1;
    localparam int unsigned VIRTIO_NET_RSS_HASH_TYPE_UDPv4    = 2;
    localparam int unsigned VIRTIO_NET_RSS_HASH_TYPE_IPv6     = 3;
    localparam int unsigned VIRTIO_NET_RSS_HASH_TYPE_TCPv6    = 4;
    localparam int unsigned VIRTIO_NET_RSS_HASH_TYPE_UDPv6    = 5;
    localparam int unsigned VIRTIO_NET_RSS_HASH_TYPE_IPv6_EX  = 6;
    localparam int unsigned VIRTIO_NET_RSS_HASH_TYPE_TCPv6_EX = 7;
    localparam int unsigned VIRTIO_NET_RSS_HASH_TYPE_UDPv6_EX = 8;

    // Protocol constants
    localparam int unsigned ETH_HDR_LEN     = 14;
    localparam int unsigned VLAN_TAG_LEN    = 4;
    localparam int unsigned ETHERTYPE_VLAN  = 16'h8100;
    localparam int unsigned ETHERTYPE_IPV4  = 16'h0800;
    localparam int unsigned ETHERTYPE_IPV6  = 16'h86DD;
    localparam int unsigned IPPROTO_TCP     = 6;
    localparam int unsigned IPPROTO_UDP     = 17;

    function new(string name = "virtio_rss_engine");
        super.new(name);
        init_default_key();
        // Default indirection table: 128 entries, all mapping to queue 0
        indirection_table = new[128];
        foreach (indirection_table[i])
            indirection_table[i] = 0;
        hash_types = 32'hFFFFFFFF; // All types enabled by default
    endfunction

    // ------------------------------------------------------------------------
    // configure — apply RSS configuration from virtio_rss_config_t
    // ------------------------------------------------------------------------
    function void configure(virtio_rss_config_t cfg);
        hash_key_size = cfg.hash_key_size;
        if (cfg.hash_key.size() > 0) begin
            hash_key = new[cfg.hash_key.size()];
            foreach (cfg.hash_key[i])
                hash_key[i] = cfg.hash_key[i];
        end
        if (cfg.indirection_table.size() > 0) begin
            indirection_table = new[cfg.indirection_table.size()];
            foreach (cfg.indirection_table[i])
                indirection_table[i] = cfg.indirection_table[i];
        end
        hash_types = cfg.hash_types;
    endfunction

    // ------------------------------------------------------------------------
    // init_default_key — Microsoft RSS default 40-byte Toeplitz hash key
    // ------------------------------------------------------------------------
    function void init_default_key();
        hash_key = new[40];
        hash_key = '{
            8'h6d, 8'h5a, 8'h56, 8'hda, 8'h25, 8'h5b, 8'h0e, 8'hc2,
            8'h41, 8'h67, 8'h25, 8'h3d, 8'h43, 8'ha3, 8'h8f, 8'hb0,
            8'hd0, 8'hca, 8'h2b, 8'hcb, 8'hae, 8'h7b, 8'h30, 8'hb4,
            8'h77, 8'hcb, 8'h2d, 8'ha3, 8'h80, 8'h30, 8'hf2, 8'h0c,
            8'h6a, 8'h42, 8'hb7, 8'h3b, 8'hbe, 8'hac, 8'h01, 8'hfa
        };
    endfunction

    // ------------------------------------------------------------------------
    // get_hash_type — determine which RSS hash type applies to this packet
    // Returns the hash type bitmask value for the matched type, or 0.
    // ------------------------------------------------------------------------
    function int unsigned get_hash_type(byte unsigned pkt_data[$]);
        bit [15:0] etype;
        bit [7:0] proto;
        int unsigned l2_len;

        if (pkt_data.size() < ETH_HDR_LEN)
            return 0;

        etype = {pkt_data[12], pkt_data[13]};
        l2_len = (etype == ETHERTYPE_VLAN) ?
                 ETH_HDR_LEN + VLAN_TAG_LEN : ETH_HDR_LEN;
        if (etype == ETHERTYPE_VLAN && pkt_data.size() >= l2_len + 2)
            etype = {pkt_data[16], pkt_data[17]};

        if (etype == ETHERTYPE_IPV4) begin
            if (pkt_data.size() > l2_len + 9)
                proto = pkt_data[l2_len + 9];
            else
                proto = 8'h00;

            if (proto == IPPROTO_TCP && hash_types[VIRTIO_NET_RSS_HASH_TYPE_TCPv4])
                return (1 << VIRTIO_NET_RSS_HASH_TYPE_TCPv4);
            else if (proto == IPPROTO_UDP && hash_types[VIRTIO_NET_RSS_HASH_TYPE_UDPv4])
                return (1 << VIRTIO_NET_RSS_HASH_TYPE_UDPv4);
            else if (hash_types[VIRTIO_NET_RSS_HASH_TYPE_IPv4])
                return (1 << VIRTIO_NET_RSS_HASH_TYPE_IPv4);
        end else if (etype == ETHERTYPE_IPV6) begin
            if (pkt_data.size() > l2_len + 6)
                proto = pkt_data[l2_len + 6];
            else
                proto = 8'h00;

            if (proto == IPPROTO_TCP && hash_types[VIRTIO_NET_RSS_HASH_TYPE_TCPv6])
                return (1 << VIRTIO_NET_RSS_HASH_TYPE_TCPv6);
            else if (proto == IPPROTO_UDP && hash_types[VIRTIO_NET_RSS_HASH_TYPE_UDPv6])
                return (1 << VIRTIO_NET_RSS_HASH_TYPE_UDPv6);
            else if (hash_types[VIRTIO_NET_RSS_HASH_TYPE_IPv6])
                return (1 << VIRTIO_NET_RSS_HASH_TYPE_IPv6);
        end

        return 0;
    endfunction

    // ------------------------------------------------------------------------
    // extract_rss_input — extract flow tuple bytes from packet
    // For TCP/UDP: {src_ip, dst_ip, src_port, dst_port}
    // For IP only: {src_ip, dst_ip}
    // ------------------------------------------------------------------------
    protected function void extract_rss_input(byte unsigned pkt_data[$], ref byte unsigned input_bytes[$]);
        bit [15:0] etype;
        bit [7:0] proto;
        int unsigned l2_len, l3_len;
        int unsigned l4_off;
        bit include_ports;
        bit [3:0] ihl;

        input_bytes = {};

        etype = {pkt_data[12], pkt_data[13]};
        l2_len = (etype == ETHERTYPE_VLAN) ?
                 ETH_HDR_LEN + VLAN_TAG_LEN : ETH_HDR_LEN;
        if (etype == ETHERTYPE_VLAN)
            etype = {pkt_data[16], pkt_data[17]};

        if (etype == ETHERTYPE_IPV4) begin
            if (pkt_data.size() > l2_len + 9)
                proto = pkt_data[l2_len + 9];
            else
                proto = 8'h00;

            ihl = pkt_data[l2_len][7:4];
            l3_len = (ihl < 5) ? 20 : ihl * 4;

            include_ports = (proto == IPPROTO_TCP || proto == IPPROTO_UDP);

            // src_ip (4 bytes at IP offset 12)
            for (int i = 0; i < 4; i++)
                input_bytes.push_back(pkt_data[l2_len + 12 + i]);
            // dst_ip (4 bytes at IP offset 16)
            for (int i = 0; i < 4; i++)
                input_bytes.push_back(pkt_data[l2_len + 16 + i]);

            if (include_ports) begin
                l4_off = l2_len + l3_len;
                if (pkt_data.size() > l4_off + 3) begin
                    // src_port (2 bytes)
                    input_bytes.push_back(pkt_data[l4_off]);
                    input_bytes.push_back(pkt_data[l4_off + 1]);
                    // dst_port (2 bytes)
                    input_bytes.push_back(pkt_data[l4_off + 2]);
                    input_bytes.push_back(pkt_data[l4_off + 3]);
                end
            end
        end else if (etype == ETHERTYPE_IPV6) begin
            if (pkt_data.size() > l2_len + 6)
                proto = pkt_data[l2_len + 6];
            else
                proto = 8'h00;

            l3_len = 40;
            include_ports = (proto == IPPROTO_TCP || proto == IPPROTO_UDP);

            // src_ip (16 bytes at IP offset 8)
            for (int i = 0; i < 16; i++)
                input_bytes.push_back(pkt_data[l2_len + 8 + i]);
            // dst_ip (16 bytes at IP offset 24)
            for (int i = 0; i < 16; i++)
                input_bytes.push_back(pkt_data[l2_len + 24 + i]);

            if (include_ports) begin
                l4_off = l2_len + l3_len;
                if (pkt_data.size() > l4_off + 3) begin
                    input_bytes.push_back(pkt_data[l4_off]);
                    input_bytes.push_back(pkt_data[l4_off + 1]);
                    input_bytes.push_back(pkt_data[l4_off + 2]);
                    input_bytes.push_back(pkt_data[l4_off + 3]);
                end
            end
        end
    endfunction

    // ------------------------------------------------------------------------
    // toeplitz_hash — core Toeplitz hash algorithm
    //
    // For each bit in the input, if the bit is 1, XOR the result with a
    // 32-bit value derived from the key starting at that bit position.
    // The 32-bit value is a sliding window across the key.
    // ------------------------------------------------------------------------
    protected function bit [31:0] toeplitz_hash(byte unsigned key_bytes[$], byte unsigned input_bytes[$]);
        bit [31:0] result;
        int unsigned input_len_bits;
        bit input_bit;
        bit [31:0] key_word;
        int unsigned byte_idx, bit_idx;
        int unsigned k_byte, k_bit;

        result = 32'h0;
        input_len_bits = input_bytes.size() * 8;

        // Need key to be at least (input_len_bits/8 + 4) bytes
        for (int unsigned i = 0; i < input_len_bits; i++) begin
            // Get input bit (MSB first within each byte)
            byte_idx = i / 8;
            bit_idx  = 7 - (i % 8);
            input_bit = input_bytes[byte_idx][bit_idx];

            if (input_bit) begin
                // Build 32-bit key word starting at bit position i
                key_word = 32'h0;
                for (int unsigned j = 0; j < 32; j++) begin
                    k_byte = (i + j) / 8;
                    k_bit  = 7 - ((i + j) % 8);
                    if (k_byte < key_bytes.size())
                        key_word[31 - j] = key_bytes[k_byte][k_bit];
                end
                result = result ^ key_word;
            end
        end

        return result;
    endfunction

    // ------------------------------------------------------------------------
    // calc_hash — compute Toeplitz hash for a packet
    // Extracts flow tuple and hashes with configured key.
    // ------------------------------------------------------------------------
    function bit [31:0] calc_hash(byte unsigned pkt_data[$]);
        byte unsigned input_bytes[$];
        int unsigned hash_type_val;

        hash_type_val = get_hash_type(pkt_data);
        if (hash_type_val == 0)
            return 32'h0;

        extract_rss_input(pkt_data, input_bytes);

        if (input_bytes.size() == 0)
            return 32'h0;

        return toeplitz_hash(hash_key, input_bytes);
    endfunction

    // ------------------------------------------------------------------------
    // lookup_queue — map hash value to queue via indirection table
    // Uses low bits of hash as index into the table.
    // ------------------------------------------------------------------------
    function int unsigned lookup_queue(bit [31:0] hash_value);
        int unsigned idx;
        if (indirection_table.size() == 0)
            return 0;
        idx = hash_value % indirection_table.size();
        return indirection_table[idx];
    endfunction

    // ------------------------------------------------------------------------
    // select_queue — full RSS pipeline: hash + lookup, clamped to num_pairs
    // ------------------------------------------------------------------------
    function int unsigned select_queue(byte unsigned pkt_data[$], int unsigned num_pairs);
        bit [31:0] hash_val;
        int unsigned queue;

        if (num_pairs == 0)
            return 0;

        hash_val = calc_hash(pkt_data);
        if (hash_val == 32'h0)
            return 0;

        queue = lookup_queue(hash_val);

        // Clamp to valid range
        if (queue >= num_pairs)
            queue = queue % num_pairs;

        return queue;
    endfunction

endclass : virtio_rss_engine

`endif // VIRTIO_RSS_ENGINE_SV

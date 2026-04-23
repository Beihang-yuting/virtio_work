`ifndef VIRTIO_NET_HDR_SV
`define VIRTIO_NET_HDR_SV

// ============================================================================
// virtio_net_hdr_util
//
// Utility class providing static methods for serializing and deserializing
// virtio_net_hdr_t to/from little-endian byte arrays. Header size depends
// on negotiated features:
//   - 10 bytes  : basic header (flags, gso_type, hdr_len, gso_size,
//                               csum_start, csum_offset)
//   - 12 bytes  : + num_buffers  (VIRTIO_NET_F_MRG_RXBUF)
//   - 20 bytes  : + hash_value, hash_report (VIRTIO_NET_F_HASH_REPORT)
// ============================================================================

class virtio_net_hdr_util;

    // ------------------------------------------------------------------------
    // get_hdr_size
    //
    // Returns the wire size of virtio_net_hdr in bytes given negotiated
    // feature bits.
    // ------------------------------------------------------------------------
    static function int unsigned get_hdr_size(bit [63:0] features);
        if (features[VIRTIO_NET_F_HASH_REPORT])
            return 20;
        else if (features[VIRTIO_NET_F_MRG_RXBUF])
            return 12;
        else
            return 10;
    endfunction : get_hdr_size

    // ------------------------------------------------------------------------
    // pack_hdr
    //
    // Serializes hdr into little-endian bytes appended to data[].
    // Byte layout (all fields little-endian):
    //   [0]      flags         (8-bit)
    //   [1]      gso_type      (8-bit)
    //   [3:2]    hdr_len       (16-bit LE)
    //   [5:4]    gso_size      (16-bit LE)
    //   [7:6]    csum_start    (16-bit LE)
    //   [9:8]    csum_offset   (16-bit LE)
    //  (if MRG_RXBUF or HASH_REPORT)
    //   [11:10]  num_buffers   (16-bit LE)
    //  (if HASH_REPORT)
    //   [15:12]  hash_value    (32-bit LE)
    //   [17:16]  hash_report   (16-bit LE)
    //   [19:18]  padding       (16-bit, zeroed)
    // ------------------------------------------------------------------------
    static function void pack_hdr(
        virtio_net_hdr_t    hdr,
        bit [63:0]          features,
        ref byte unsigned   data[$]
    );
        int unsigned hdr_size;

        hdr_size = get_hdr_size(features);

        // flags (byte 0)
        data.push_back(hdr.flags);

        // gso_type (byte 1)
        data.push_back(hdr.gso_type);

        // hdr_len (bytes 2-3, little-endian)
        data.push_back(hdr.hdr_len[7:0]);
        data.push_back(hdr.hdr_len[15:8]);

        // gso_size (bytes 4-5, little-endian)
        data.push_back(hdr.gso_size[7:0]);
        data.push_back(hdr.gso_size[15:8]);

        // csum_start (bytes 6-7, little-endian)
        data.push_back(hdr.csum_start[7:0]);
        data.push_back(hdr.csum_start[15:8]);

        // csum_offset (bytes 8-9, little-endian)
        data.push_back(hdr.csum_offset[7:0]);
        data.push_back(hdr.csum_offset[15:8]);

        if (hdr_size >= 12) begin
            // num_buffers (bytes 10-11, little-endian)
            data.push_back(hdr.num_buffers[7:0]);
            data.push_back(hdr.num_buffers[15:8]);
        end

        if (hdr_size >= 20) begin
            // hash_value (bytes 12-15, little-endian)
            data.push_back(hdr.hash_value[7:0]);
            data.push_back(hdr.hash_value[15:8]);
            data.push_back(hdr.hash_value[23:16]);
            data.push_back(hdr.hash_value[31:24]);

            // hash_report (bytes 16-17, little-endian)
            data.push_back(hdr.hash_report[7:0]);
            data.push_back(hdr.hash_report[15:8]);

            // padding (bytes 18-19, zeroed)
            data.push_back(8'h00);
            data.push_back(8'h00);
        end
    endfunction : pack_hdr

    // ------------------------------------------------------------------------
    // unpack_hdr
    //
    // Deserializes hdr from little-endian bytes in data[].
    // Reads exactly get_hdr_size(features) bytes from the front of data[].
    // Fields not present in the negotiated header size are zeroed.
    // ------------------------------------------------------------------------
    static function void unpack_hdr(
        byte unsigned        data[$],
        bit [63:0]           features,
        ref virtio_net_hdr_t hdr
    );
        int unsigned hdr_size;

        hdr_size = get_hdr_size(features);

        // Zero all fields first
        hdr.flags        = 8'h00;
        hdr.gso_type     = 8'h00;
        hdr.hdr_len      = 16'h0000;
        hdr.gso_size     = 16'h0000;
        hdr.csum_start   = 16'h0000;
        hdr.csum_offset  = 16'h0000;
        hdr.num_buffers  = 16'h0000;
        hdr.hash_value   = 32'h00000000;
        hdr.hash_report  = 16'h0000;

        if (data.size() < hdr_size)
            return;

        // flags (byte 0)
        hdr.flags = data[0];

        // gso_type (byte 1)
        hdr.gso_type = data[1];

        // hdr_len (bytes 2-3, little-endian)
        hdr.hdr_len = {data[3], data[2]};

        // gso_size (bytes 4-5, little-endian)
        hdr.gso_size = {data[5], data[4]};

        // csum_start (bytes 6-7, little-endian)
        hdr.csum_start = {data[7], data[6]};

        // csum_offset (bytes 8-9, little-endian)
        hdr.csum_offset = {data[9], data[8]};

        if (hdr_size >= 12) begin
            // num_buffers (bytes 10-11, little-endian)
            hdr.num_buffers = {data[11], data[10]};
        end

        if (hdr_size >= 20) begin
            // hash_value (bytes 12-15, little-endian)
            hdr.hash_value = {data[15], data[14], data[13], data[12]};

            // hash_report (bytes 16-17, little-endian)
            hdr.hash_report = {data[17], data[16]};
            // bytes 18-19 are padding, ignored
        end
    endfunction : unpack_hdr

endclass : virtio_net_hdr_util

`endif // VIRTIO_NET_HDR_SV

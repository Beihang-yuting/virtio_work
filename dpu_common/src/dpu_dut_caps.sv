`ifndef DPU_DUT_CAPS_SV
`define DPU_DUT_CAPS_SV

class dpu_dut_caps extends uvm_object;
    `uvm_object_utils(dpu_dut_caps)

    int unsigned max_hosts;
    int unsigned max_pfs_per_host;
    int unsigned max_vfs_per_pf;
    int unsigned max_functions;
    int unsigned global_msix_vector_count;
    // Interrupt resources which the real driver reserves after the LAN
    // vectors for each active function.  AF additionally owns the extra
    // control/message vectors; keeping these in capabilities makes the
    // resource snapshot explicit instead of hiding the accounting in the
    // register-plan builder.
    int unsigned mailbox_msix_vectors;
    int unsigned af_extra_msix_vectors;
    int unsigned af_extra_queue_count;
    int unsigned vio_global_qpair_count;
    int unsigned max_vio_net_qpairs_per_device;
    int unsigned vio_notify_entries_per_bank;
    dpu_bar_profile_t bar_profiles[$];

    protected function void add_bar_profile(
        input dpu_function_kind_e kind,
        input dpu_bar_role_e role,
        input int unsigned even_bar_id,
        input bit [63:0] size,
        input bit [63:0] alignment
    );
        dpu_bar_profile_t profile;

        profile.kind = kind;
        profile.role = role;
        profile.even_bar_id = even_bar_id;
        profile.size = size;
        profile.alignment = alignment;
        bar_profiles.push_back(profile);
    endfunction

    function new(string name = "dpu_dut_caps");
        super.new(name);
        max_hosts = 2;
        max_pfs_per_host = 4;
        max_vfs_per_pf = 16;
        max_functions = DPU_MAX_FUNCTIONS;
        global_msix_vector_count = DPU_MAX_GLOBAL_MSIX_VECTORS;
        mailbox_msix_vectors = 1;
        // dpu_configure_msix_map(): DPU_AF_EXTRA_INTR_NUM - 1.
        af_extra_msix_vectors = 13;
        // common.h: forward + BPDU + 2 ports * 4 netdev + PTP.
        af_extra_queue_count = DPU_DRIVER_AF_EXTRA_QUEUE_COUNT;
        vio_global_qpair_count = DPU_MAX_VIO_GLOBAL_QPAIRS;
        max_vio_net_qpairs_per_device = DPU_VIO_NET_MAX_QPAIRS_PER_DEVICE;
        // DPU_QID_MAP_TABLE_ENTRIES == DPU_MAX_TXRX_QUEUE == 128 in the
        // audited driver, even though the encoded table aperture is larger.
        vio_notify_entries_per_bank =
            DPU_DRIVER_VIO_NOTIFY_ENTRIES_PER_BANK;
        add_bar_profile(DPU_FUNCTION_PF, DPU_BAR_DEVICE_MEMORY, 0,
                        64'h0000_0000_0200_0000, 64'h0000_0000_0200_0000);
        add_bar_profile(DPU_FUNCTION_PF, DPU_BAR_MAILBOX, 2,
                        64'h0000_0000_0001_0000, 64'h0000_0000_0001_0000);
        add_bar_profile(DPU_FUNCTION_PF, DPU_BAR_MSIX, 4,
                        64'h0000_0000_0001_0000, 64'h0000_0000_0001_0000);
        add_bar_profile(DPU_FUNCTION_VF, DPU_BAR_DEVICE_MEMORY, 0,
                        64'h0000_0000_0000_4000, 64'h0000_0000_0000_4000);
        add_bar_profile(DPU_FUNCTION_VF, DPU_BAR_MAILBOX, 2,
                        64'h0000_0000_0000_4000, 64'h0000_0000_0000_4000);
        add_bar_profile(DPU_FUNCTION_VF, DPU_BAR_MSIX, 4,
                        64'h0000_0000_0000_8000, 64'h0000_0000_0000_8000);
    endfunction

    function void copy_from(input dpu_dut_caps rhs);
        max_hosts = rhs.max_hosts;
        max_pfs_per_host = rhs.max_pfs_per_host;
        max_vfs_per_pf = rhs.max_vfs_per_pf;
        max_functions = rhs.max_functions;
        global_msix_vector_count = rhs.global_msix_vector_count;
        mailbox_msix_vectors = rhs.mailbox_msix_vectors;
        af_extra_msix_vectors = rhs.af_extra_msix_vectors;
        af_extra_queue_count = rhs.af_extra_queue_count;
        vio_global_qpair_count = rhs.vio_global_qpair_count;
        max_vio_net_qpairs_per_device = rhs.max_vio_net_qpairs_per_device;
        vio_notify_entries_per_bank = rhs.vio_notify_entries_per_bank;
        bar_profiles.delete();
        foreach (rhs.bar_profiles[index])
            bar_profiles.push_back(rhs.bar_profiles[index]);
    endfunction

    function bit lookup_bar_profile(
        input dpu_function_kind_e kind,
        input dpu_bar_role_e role,
        output dpu_bar_profile_t profile,
        output string why
    );
        foreach (bar_profiles[index]) begin
            if ((bar_profiles[index].kind == kind) &&
                (bar_profiles[index].role == role)) begin
                profile = bar_profiles[index];
                why = "";
                return 1;
            end
        end
        profile.kind = DPU_FUNCTION_PF;
        profile.role = DPU_BAR_DEVICE_MEMORY;
        profile.even_bar_id = 0;
        profile.size = '0;
        profile.alignment = '0;
        why = $sformatf("no BAR profile for function kind %0d role %0d",
                        kind, role);
        return 0;
    endfunction

    function bit validate(output string why);
        why = "";
        if (max_hosts == 0) begin
            why = "DUT host capability must be nonzero";
            return 0;
        end
        if (max_hosts > DPU_MAX_HOSTS) begin
            why = "DUT host capability exceeds the model ceiling";
            return 0;
        end
        if (max_pfs_per_host == 0) begin
            why = "DUT PF capability must be nonzero";
            return 0;
        end
        if (max_pfs_per_host > DPU_MAX_PFS_PER_HOST) begin
            why = "DUT PF capability exceeds the model ceiling";
            return 0;
        end
        if (max_vfs_per_pf == 0) begin
            why = "DUT VF capability must be nonzero";
            return 0;
        end
        if (max_vfs_per_pf > DPU_MAX_VFS_PER_PF) begin
            why = "DUT VF capability exceeds the model ceiling";
            return 0;
        end
        if (max_functions == 0) begin
            why = "DUT function capability must be nonzero";
            return 0;
        end
        if (max_functions > DPU_MAX_FUNCTIONS) begin
            why = "DUT function capability exceeds the model ceiling";
            return 0;
        end
        if (global_msix_vector_count == 0) begin
            why = "DUT global MSI-X capability must be nonzero";
            return 0;
        end
        if (global_msix_vector_count > DPU_MAX_GLOBAL_MSIX_VECTORS) begin
            why = "DUT global MSI-X capability exceeds the model ceiling";
            return 0;
        end
        if (mailbox_msix_vectors > global_msix_vector_count) begin
            why = "DUT mailbox MSI-X capability exceeds global vector capacity";
            return 0;
        end
        if (af_extra_msix_vectors > global_msix_vector_count) begin
            why = "DUT AF extra MSI-X capability exceeds global vector capacity";
            return 0;
        end
        if (af_extra_queue_count > DPU_DRIVER_AF_EXTRA_QUEUE_COUNT) begin
            why = "DUT AF extra queue capability exceeds the audited driver layout";
            return 0;
        end
        if (af_extra_queue_count > max_vio_net_qpairs_per_device) begin
            why = "DUT AF extra queue capability exceeds per-device qpair capacity";
            return 0;
        end
        if (af_extra_msix_vectors < af_extra_queue_count) begin
            why = "DUT AF extra MSI-X capability cannot cover AF extra queues";
            return 0;
        end
        if (vio_global_qpair_count == 0) begin
            why = "DUT VIO global qpair capability must be nonzero";
            return 0;
        end
        if (vio_global_qpair_count > DPU_MAX_VIO_GLOBAL_QPAIRS) begin
            why = "DUT VIO global qpair capability exceeds the 11-bit ID domain";
            return 0;
        end
        if (max_vio_net_qpairs_per_device == 0) begin
            why = "DUT VIO-net device capability must be nonzero";
            return 0;
        end
        if (max_vio_net_qpairs_per_device >
            DPU_VIO_NET_MAX_QPAIRS_PER_DEVICE) begin
            why = "DUT VIO-net device capability exceeds 32 qpairs";
            return 0;
        end
        if (vio_notify_entries_per_bank == 0) begin
            why = "DUT VIO notify capability must be nonzero";
            return 0;
        end
        if (vio_notify_entries_per_bank >
            DPU_MAX_VIO_NOTIFY_ENTRIES_PER_BANK) begin
            why = "DUT VIO notify capability exceeds the model ceiling";
            return 0;
        end
        foreach (bar_profiles[first]) begin
            for (int second = first + 1;
                 second < bar_profiles.size(); second++) begin
                if ((bar_profiles[first].kind == bar_profiles[second].kind) &&
                    (bar_profiles[first].role == bar_profiles[second].role)) begin
                    why = $sformatf(
                        "DUT BAR profiles duplicate function kind %0d role %0d",
                        bar_profiles[first].kind, bar_profiles[first].role);
                    return 0;
                end
                if ((bar_profiles[first].kind == bar_profiles[second].kind) &&
                    (bar_profiles[first].even_bar_id ==
                     bar_profiles[second].even_bar_id)) begin
                    why = $sformatf(
                        "DUT BAR profiles duplicate function kind %0d BAR%0d",
                        bar_profiles[first].kind,
                        bar_profiles[first].even_bar_id);
                    return 0;
                end
            end
        end
        return 1;
    endfunction
endclass : dpu_dut_caps

`endif // DPU_DUT_CAPS_SV

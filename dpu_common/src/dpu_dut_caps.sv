`ifndef DPU_DUT_CAPS_SV
`define DPU_DUT_CAPS_SV

class dpu_dut_caps extends uvm_object;
    `uvm_object_utils(dpu_dut_caps)

    int unsigned max_hosts;
    int unsigned max_pfs_per_host;
    int unsigned max_vfs_per_pf;
    int unsigned max_functions;
    int unsigned global_msix_vector_count;
    int unsigned vio_global_qpair_count;
    int unsigned max_vio_net_qpairs_per_device;
    int unsigned vio_notify_entries_per_bank;

    function new(string name = "dpu_dut_caps");
        super.new(name);
        max_hosts = 2;
        max_pfs_per_host = 4;
        max_vfs_per_pf = 16;
        max_functions = DPU_MAX_FUNCTIONS;
        global_msix_vector_count = DPU_MAX_GLOBAL_MSIX_VECTORS;
        vio_global_qpair_count = DPU_MAX_VIO_GLOBAL_QPAIRS;
        max_vio_net_qpairs_per_device = DPU_VIO_NET_MAX_QPAIRS_PER_DEVICE;
        vio_notify_entries_per_bank = DPU_MAX_VIO_NOTIFY_ENTRIES_PER_BANK;
    endfunction

    function void copy_from(input dpu_dut_caps rhs);
        max_hosts = rhs.max_hosts;
        max_pfs_per_host = rhs.max_pfs_per_host;
        max_vfs_per_pf = rhs.max_vfs_per_pf;
        max_functions = rhs.max_functions;
        global_msix_vector_count = rhs.global_msix_vector_count;
        vio_global_qpair_count = rhs.vio_global_qpair_count;
        max_vio_net_qpairs_per_device = rhs.max_vio_net_qpairs_per_device;
        vio_notify_entries_per_bank = rhs.vio_notify_entries_per_bank;
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
        return 1;
    endfunction
endclass : dpu_dut_caps

`endif // DPU_DUT_CAPS_SV

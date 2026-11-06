// 原生 TL 参考集成入口。从 virtio_work 根运行；依赖根由调用方提供。
// 已有统一工程 filelist 时，按此顺序增补缺失包，禁止把已有包再次编译。
-f filelists/aip_integration.f
+incdir+integration/project
integration/project/project_env_pkg.sv

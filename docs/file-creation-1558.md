# #1558 文件不存在时创建空文件

文件预览读取返回 ENOENT 时，显示目标主机/路径和“创建此文件”。点击后通过当前连接的 fs.entry.create.request 创建空文件，再重新读取。服务端能力缺失时说明不支持；权限、断连等错误不提供创建入口。

复用服务端 wx 独占创建，不覆盖现有文件，不自动建立父目录。文件树中的相对路径拆为 parentPath/name，保留 cwd；拒绝路径穿越、空路径段和服务端会 trim 的文件名。

## 验证

- PaseoKit EmptyFileCreationTests：3 项通过，覆盖错误分类、根目录/子目录请求、非法路径和失败响应。
- 已安装 daemon 的 createExplorerEntry 在临时沙盒执行：空文件大小为 0；同名已有内容不被覆盖；并发创建同一路径只有一个成功。未写入真实密钥文件。
- 独立静态评审修复了文件树子目录路径问题，增量复审通过。
- 最终合并工作区 Mac 编译及 TimelinePerformanceTests/StreamReplayTests 共 11 项通过，iOS 编译及 FileSourceTests/MobileFeatureTests 共 2 项通过；尚未安装到日常使用的 App，人工点击验收待进行。

## 人工验收

打开当前主机下不存在的文件链接，确认目标提示正确，点击创建后预览为空；重新点击已存在文件不覆盖内容。父目录不存在时显示真实创建错误。

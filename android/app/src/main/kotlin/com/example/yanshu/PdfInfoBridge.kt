package com.example.yanshu

import android.graphics.pdf.PdfRenderer
import android.os.ParcelFileDescriptor
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMethodCodec
import java.io.File

class PdfInfoBridge(messenger: BinaryMessenger) {
    private val channel = MethodChannel(
        messenger,
        "yanshu/pdf_info",
        StandardMethodCodec.INSTANCE,
        messenger.makeBackgroundTaskQueue()
    )

    init {
        channel.setMethodCallHandler { call, result ->
            if (call.method != "firstPageSize") {
                result.notImplemented()
                return@setMethodCallHandler
            }

            try {
                val path = requireNotNull(call.argument<String>("path"))
                ParcelFileDescriptor.open(File(path), ParcelFileDescriptor.MODE_READ_ONLY).use { descriptor ->
                    // 只读取首页尺寸；不生成位图，所有资源在读取后关闭。
                    PdfRenderer(descriptor).use { renderer ->
                        renderer.openPage(0).use { page ->
                            result.success(listOf(page.width, page.height))
                        }
                    }
                }
            } catch (error: Exception) {
                result.error("pdf_info_failed", "无法读取 PDF 首页尺寸", null)
            }
        }
    }

    fun close() = channel.setMethodCallHandler(null)
}

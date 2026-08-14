// MINTED — Phoenix LiveView socket setup
//
// Main JavaScript entry point. Connects the LiveView socket with
// client-side hooks.

import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"

import QRCodeHook from "./hooks/qr_code_hook"
import WalletBridge from "./hooks/wallet_bridge"

let Hooks = {
  WalletBridge,
  FlashAutoClear: {
    mounted() {
      const ms = parseInt(this.el.dataset.dismissAfter || "4000", 10)
      this.timer = setTimeout(() => {
        this.el.style.transition = "opacity 0.5s ease-in"
        this.el.style.opacity = "0"
        setTimeout(() => this.el.click(), 500)
      }, ms)
    },
    destroyed() {
      if (this.timer) clearTimeout(this.timer)
    }
  },
  QRCode: QRCodeHook,
  CopyClipboard: {
    mounted() {
      this.el.addEventListener("click", () => {
        const text = this.el.dataset.clipboardText
        if (text && navigator.clipboard) navigator.clipboard.writeText(text)
        const targetId = this.el.dataset.selectTarget
        if (targetId) {
          const el = document.getElementById(targetId)
          if (el) {
            const range = document.createRange()
            range.selectNodeContents(el)
            const sel = window.getSelection()
            sel.removeAllRanges()
            sel.addRange(range)
          }
        }
      })
    }
  },
  SelectAndCopy: {
    mounted() {
      this.el.addEventListener("click", () => {
        if (!this.el.value) return
        this.el.select()
      })
    }
  }
}

let csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
let liveSocket = new LiveSocket("/live", Socket, {
  params: {_csrf_token: csrfToken},
  hooks: Hooks,
  heartbeatIntervalMs: 60000
})

liveSocket.connect()

window.liveSocket = liveSocket

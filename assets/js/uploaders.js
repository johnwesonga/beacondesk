let Uploaders = {}

Uploaders.Tigris = function (entries, onViewError) {
    entries.forEach(entry => {
        let formData = new FormData()
        let { url, fields } = entry.meta
        Object.entries(fields).forEach(([key, val]) => formData.append(key, val))
        formData.append("file", entry.file)
        let xhr = new XMLHttpRequest()
        onViewError(() => xhr.abort())
        xhr.onload = () => {
            if (xhr.status >= 200 && xhr.status < 300) {
                entry.progress(100)
            } else {
                entry.error()
            }
        }

        xhr.onerror = () => {
            entry.error()
        }
        xhr.upload.addEventListener("progress", (event) => {
            if (event.lengthComputable) {
                let percent = Math.round((event.loaded / event.total) * 100)
                if (percent < 100) {
                    entry.progress(percent)
                }
            }
        })

        xhr.open("POST", url, true)
        xhr.send(formData)
    })
}

export default Uploaders;
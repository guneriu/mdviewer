# Untrusted document

<script>window.hardeningExecuted = true</script>
<img src="https://mdviewer-m4.invalid/leak" srcset="https://mdviewer-m4.invalid/leak2 2x" onerror="window.hardeningExecuted = true">
<iframe src="https://mdviewer-m4.invalid/frame"></iframe>
<object data="file:///etc/passwd"></object>
<form action="https://mdviewer-m4.invalid/post"><input name="source"></form>
<svg><a xlink:href="javascript:window.hardeningExecuted=true">unsafe</a></svg>
<style>@import 'https://mdviewer-m4.invalid/style';</style>
<meta http-equiv="refresh" content="0;url=https://mdviewer-m4.invalid/redirect">

[script](javascript:window.hardeningExecuted=true)
[data](data:text/html;base64,PHNjcmlwdD4=)
[custom](x-invalid:run)
[executable](run.sh)
[malformed](https://user:password@example.invalid/)

![remote](https://mdviewer-m4.invalid/remote.png)
![absolute](/etc/passwd)
![encoded traversal](%2e%2e/outside.png)
![symlink](Images/escape.png)
![NUL](Images/pixel.png%00.png)
![encoded slash](Images%2f..%2f..%2foutside.png)
![double encoded](%252e%252e/outside.png)
![query](Images/pixel.png?leak=1)
![fragment](Images/pixel.png#leak)
![SVG](Images/hostile.svg)
![data](data:image/svg+xml;base64,PHN2Zy8+)

```javascript
const answer = 42;
```
```typescript
interface Value { answer: number; }
```
```json
{"answer": 42}
```
```css
body { color: red; }
```
```xml
<report answer="42" />
```
```bash
echo "$HOME"
```
```python
def answer(): return 42
```
```swift
let answer: Int = 42
```

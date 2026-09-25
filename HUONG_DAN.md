# Hướng dẫn thực hành CI/CD với GitHub Actions — dự án FeeCalc

FeeCalc là API tính phí giao dịch chứng khoán (C# / .NET 8). Code **cố tình có lỗi**: lệnh đặt
online phải tính 0,15% nhưng đang tính 0,25% như lệnh tại quầy. Bài tập là sửa lỗi này theo đúng
quy trình: nhánh → test → Pull Request → CI → merge → tự lên UAT → duyệt → tự lên PROD.

## 1. Bức tranh tổng thể

```
 Máy dev                    GitHub (cloud)                          Mạng nội bộ
 ─────────                  ───────────────────────────────         ───────────────────────────────
 hotfix/online-fee ──push──► CI: format, build, test (ubuntu)
                             │ xanh
                             ▼
                            Pull Request ── review ── Merge vào main
                                                        │
                             CD: build 1 lần → gói v1.0.N
                                                        │   runner nội bộ tự "kéo" việc về
                                                        └──────────────► deploy.ps1 → servers\uat  :5081
                                                                          healthcheck + smoke test
                             [Chờ người duyệt bấm Approve]
                                                        └──────────────► deploy.ps1 → servers\prod :5082
                                                                          healthcheck, lỗi thì tự rollback
```

Ba ý cần nhớ:

1. **CI** chạy trên máy ảo GitHub, chỉ cần mã nguồn. **CD** chạy trên *self-hosted runner*, là
   máy duy nhất trong mạng nội bộ chạm được máy chủ. Runner chủ động gọi ra GitHub (cổng 443), nên
   không phải mở cổng nào từ Internet vào.
2. **Build một lần, deploy nhiều nơi.** UAT và PROD nhận *cùng một gói*. Thứ đã test ở UAT chính
   là thứ lên PROD, không build lại.
3. **Mỗi bản là một thư mục riêng** (`releases\1.0.N`), nên rollback chỉ là chạy lại thư mục cũ.

## 2. Cấu trúc repo

| Đường dẫn | Vai trò |
|---|---|
| `src/FeeCalc.Api/FeeCalculator.cs` | Logic tính phí (chỗ có lỗi) |
| `src/FeeCalc.Api/Program.cs` | API: `/`, `/health`, `/api/fee` |
| `tests/FeeCalc.Tests/` | Unit test xUnit |
| `.github/workflows/ci.yml` | CI: format → build → test |
| `.github/workflows/cd.yml` | CD: build → UAT → (duyệt) → PROD |
| `.github/workflows/rollback.yml` | Rollback bằng tay từ tab Actions |
| `deploy/deploy.ps1` | Chép gói → đổi tiến trình → healthcheck → rollback nếu lỗi |
| `deploy/rollback.ps1` | Chạy lại bản cũ có sẵn trên máy chủ |
| `global.json` | Cố định .NET SDK 8, để máy dev và CI build giống hệt nhau |

"Máy chủ" trong bản demo là thư mục `F:\GITHUB\cicd\servers\{uat,prod}`. App chạy tại
http://localhost:5081 (UAT) và http://localhost:5082 (PROD).

## 3. Thiết lập ban đầu (làm một lần)

| Việc | Ở đâu | Vì sao |
|---|---|---|
| Tạo repo, đẩy code lên `main` | `gh repo create` | |
| **Bảo vệ nhánh `main`**: bắt buộc qua PR, bắt buộc CI xanh, cấm push thẳng | Settings → Branches | Không ai đẩy code chưa test lên PROD, kể cả trưởng nhóm |
| **Environment `production`** có *Required reviewers* | Settings → Environments | Người code ≠ người bấm lên PROD |
| Cài **self-hosted runner** nhãn `bsc-demo` | Settings → Actions → Runners | Máy trong mạng nội bộ thực hiện deploy |

Khi xong, CD chạy lần đầu và đưa bản **có lỗi** lên cả UAT lẫn PROD. Kiểm tra:

```powershell
Invoke-RestMethod "http://127.0.0.1:5082/api/fee?value=10000000&channel=Online" -NoProxy
# fee = 25000  ← SAI, đúng phải là 15000 (0,15%)
```

## 4. Bài tập chính: hotfix lỗi phí online

### Bước 1 — Ghi nhận việc cần làm

```powershell
gh issue create --title "Phí lệnh online đang tính 0,25% thay vì 0,15%" --body "10.000.000đ online ra 25.000đ, đúng phải 15.000đ"
```

Mọi thay đổi đều bắt đầu từ một issue/task, để sau này tra được vì sao code bị sửa.

### Bước 2 — Tạo nhánh từ `main` mới nhất

```powershell
cd F:\GITHUB\cicd\feecalc
git switch main
git pull
git switch -c hotfix/online-fee
```

Quy ước tên nhánh: `feature/<tên>` cho tính năng, `hotfix/<tên>` cho sửa lỗi gấp. CI tự chạy khi
push lên các nhánh có tiền tố này.

### Bước 3 — Viết test chứng minh lỗi TRƯỚC khi sửa

Thêm vào `tests/FeeCalc.Tests/FeeCalculatorTests.cs`:

```csharp
[Fact]
public void Online_order_uses_online_rate()
{
    Assert.Equal(15_000m, FeeCalculator.Calculate(10_000_000m, Channel.Online));
}
```

```powershell
dotnet test
# Failed!  Expected: 15000  Actual: 25000   ← test ĐỎ, đúng như mong đợi
```

Test đỏ trước chứng minh test bắt được lỗi. Nếu test xanh ngay thì test viết sai.

### Bước 4 — Sửa code

Trong `src/FeeCalc.Api/FeeCalculator.cs`:

```csharp
// trước
var rate = CounterRate;
// sau
var rate = channel == Channel.Online ? OnlineRate : CounterRate;
```

```powershell
dotnet test      # Passed! 5/5
dotnet format    # tự căn lề cho đúng chuẩn, nếu không CI sẽ báo đỏ
```

### Bước 5 — Commit và push

```powershell
git add -A
git commit -m "fix: tính phí lệnh online theo tỷ lệ 0,15%"
git push -u origin hotfix/online-fee
```

Mở tab **Actions** trên GitHub, workflow **CI** đã tự chạy trên nhánh của bạn.

### Bước 6 — Mở Pull Request

```powershell
gh pr create --base main --fill
gh pr checks --watch      # xem CI chạy ngay trong terminal
```

Trên trang PR: CI phải xanh thì nút Merge mới bật. Người khác review. Ở demo, bạn tự merge vì chỉ
có một người. Đi làm thật, bước này bắt buộc người thứ hai duyệt.

```powershell
gh pr merge --squash --delete-branch
```

`--squash` gộp mọi commit của nhánh thành một commit trên `main`, giúp lịch sử gọn và dễ revert.

### Bước 7 — CD tự chạy: UAT → duyệt → PROD

1. Tab **Actions** → workflow **CD** đang chạy: `Build + đóng gói` → `Deploy UAT`.
2. Kiểm tra UAT đã đúng chưa:
   ```powershell
   Invoke-RestMethod "http://127.0.0.1:5081/api/fee?value=10000000&channel=Online" -NoProxy   # fee = 15000
   ```
   PROD lúc này vẫn chạy bản cũ (25000). Đây là lúc QA nghiệm thu trên UAT.
3. Job `Deploy PROD` hiện **Waiting for review**. Bấm **Review deployments → production → Approve**.
4. Kiểm tra PROD:
   ```powershell
   Invoke-RestMethod "http://127.0.0.1:5082/health" -NoProxy    # version = 1.0.N mới
   Invoke-RestMethod "http://127.0.0.1:5082/api/fee?value=10000000&channel=Online" -NoProxy   # 15000
   ```
5. Xem trên máy chủ: `F:\GITHUB\cicd\servers\prod\releases\` có cả bản cũ lẫn bản mới, và
   `history.txt` ghi lại lịch sử deploy.

Xong một vòng. Từ lúc merge đến lúc lên PROD, bạn không phải copy file hay đăng nhập máy chủ nào.

## 5. Thử phá để hiểu các lớp bảo vệ

| Thử | Kết quả mong đợi | Lớp bảo vệ |
|---|---|---|
| Sửa `OnlineRate = 0.002m` rồi push lên nhánh | CI đỏ, PR không merge được | Unit test |
| Thêm khoảng trắng lung tung rồi push | CI đỏ ở bước *Kiểm tra định dạng* | `dotnet format` |
| `git push origin main` thẳng | GitHub từ chối | Branch protection |
| Thêm `throw new Exception("boom");` ngay đầu `Program.cs` (bỏ qua test), merge | UAT deploy → app crash → **tự rollback**, job đỏ, PROD không bị đụng tới | Healthcheck + rollback |

Sau thử nghiệm cuối, nhớ revert:
`git revert <sha>` → PR → merge. Không sửa trực tiếp trên máy chủ.

## 6. Rollback bằng tay

PROD vẫn chạy nhưng nghiệp vụ báo sai, cần quay về bản trước ngay:

- Trên GitHub: **Actions → Rollback → Run workflow** → chọn `production` → để trống version.
  Rollback PROD cũng phải qua người duyệt.
- Hoặc gõ thẳng trên máy chủ:
  ```powershell
  ./deploy/rollback.ps1 -ServerRoot F:\GITHUB\cicd\servers\prod -Port 5082 -EnvName Production
  ```

Rollback chỉ là giải pháp tạm thời. Sửa lỗi thật vẫn phải đi lại từ Bước 2.

## 7. Từ demo sang máy chủ VMware thật

| Demo | Thật |
|---|---|
| Runner chạy ngay trên máy dev | Runner cài trên một VM riêng (VD `cicd-runner-01`), tách runner UAT và runner PROD |
| "Máy chủ" = thư mục trên ổ F | Runner chép gói sang VM đích qua SSH/WinRM (hoặc Ansible), hoặc cài runner ngay trên VM đích |
| App chạy bằng `cmd /c dotnet ...` | Windows Service (`sc.exe` / NSSM), IIS app pool, hoặc systemd trên Linux |
| `DEPLOY_ROOT` mặc định trong yml | Settings → Variables. Mật khẩu/khoá SSH để trong **Secrets**, không bao giờ ghi vào code |
| Tự review, tự merge | Bắt buộc ≥1 người review PR. Người duyệt PROD là trưởng nhóm/QTHT |
| Một nhánh `main` | Có thể thêm `develop` (tự lên UAT) + `main` (lên PROD) khi đội đông người |

Chuyển sang **GitLab tự dựng**, khái niệm y hệt, chỉ đổi tên:
`.github/workflows/*.yml` → `.gitlab-ci.yml` · self-hosted runner → GitLab Runner ·
Pull Request → Merge Request · environment reviewers → job `when: manual` + protected branch.
Hai script `deploy.ps1` / `rollback.ps1` dùng lại nguyên.

## 8. Bảng lệnh hay dùng

```powershell
git switch main; git pull                 # luôn bắt đầu từ main mới nhất
git switch -c feature/<ten>               # tạo nhánh
dotnet test; dotnet format                # trước khi commit
git add -A; git commit -m "feat: ..."     # feat / fix / refactor / test / docs / ci
git push -u origin <nhanh>
gh pr create --base main --fill
gh pr checks --watch
gh pr merge --squash --delete-branch
gh run list --limit 5                     # xem các lần chạy pipeline
gh run watch                              # theo dõi lần chạy hiện tại
```

import csv,json,re
from pathlib import Path
root=Path("assets/demo/ja")
def rows(n):
 with (root/(n+".csv")).open(newline="") as f:return list(csv.DictReader(f))
result=[]
def add(folder,title,content):result.append(dict(folder=folder,title=title,content=content))
for x in rows("prompts"):add("日本語・"+x["カテゴリ"],x["プロンプトタイトル"],x["プロンプト本文"])
for x in rows("contacts"):add("日本語・連絡先",f'{x["会社名"]}/{x["部署"]} {x["役職"]}/{x["担当者名"]}',x["メールアドレス"])
for x in rows("company"):add("日本語・会社情報",x["項目"],x["設定値"])
for x in rows("colors"):add("日本語・会社情報",x["カラー名 / 用途"],x["HEXコード"])
url_tags=[None,"資料URL","資料ダウンロードURL",None,"レポートURL","初期準備URL","施策資料URL","パートナー制度URL","申込URL","更新申請URL"]
normalized=[]
for i,x in enumerate(rows("emails")):
 body=x["メール本文"]
 # Only the document link changes; the company URL in the signature stays fixed.
 if url_tags[i]:body=body.replace("https://company.rev-c.com","{"+url_tags[i]+"}",1)
 if i==2:body=body.replace("弊社のWeb広告運用代行サービスにお問い合わせ", "弊社の{サービス名}にお問い合わせ")
 if i==3:body=body.replace("「Web広告運用プラン」", "「{サービス名}」")
 if i==5:body=body.replace("広告アカウント権限の共有", "{媒体名}の広告アカウント権限の共有")
 content=re.sub(r"(?<!\{)\{([^{}]+)\}(?!\})",lambda m:"{{"+m[1]+"}}",x["件名"]+"\n\n"+body)
 title=f'[{x["種別"]}] {x["用途"]}'
 add("日本語・メール",title,content)
 normalized.append({**x,"差替タグ一覧":", ".join(dict.fromkeys(re.findall(r"\{\{[^{}]+\}\}",content))),"件名":content.split("\n",1)[0],"メール本文":content.split("\n\n",1)[1]})
with (root/"emails-normalized.csv").open("w",newline="") as f:
 w=csv.DictWriter(f,fieldnames=list(normalized[0]),lineterminator="\n");w.writeheader();w.writerows(normalized)
assert len(result)==58
(root/"templates.json").write_text(json.dumps(result,ensure_ascii=False,indent=2)+"\n")
print({f:sum(x["folder"]==f for x in result) for f in dict.fromkeys(x["folder"] for x in result)})

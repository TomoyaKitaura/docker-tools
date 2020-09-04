#!/usr/bin/env bash

set -euo pipefail
export LC_ALL=C

while getopts i:r:n:t:e:v: opt; do
  case $opt in
  "i") Image_tag="${OPTARG}" ;;
  "r") Repository="${OPTARG}" ;;
  "n") New_Issue_Level="${OPTARG}" ;;
  "t") Type="${OPTARG}" ;;
  "e") Ecr_Registry="${OPTARG}" ;;
  "v") Env="${OPTARG}" ;;
  *)
    echo "Usage: $CMDNAME [-t imageTag]" 1>&2
    echo "  -t : imageTag" 1>&2
    exit 1
    ;;
  esac
done

Profile=${AWS_PROFILE:-none}
if [ "${Profile}" = "none" ]; then
  Profile=""
else
  Profile="--profile ${Profile}"
fi

function setProcessingTypeConfiguration() {
  case "${Type}" in
  # https://docs.aws.amazon.com/AmazonECR/latest/APIReference/API_ImageScanFindings.html#ECR-Type-ImageScanFindings-findingSeverityCounts
  "ECR_Image_Scan")
    Level_0="NONE"
    Level_1="CRITICAL"
    Level_2="HIGH"
    Level_3="MEDIUM"
    Level_4="LOW"
    Level_5="INFORMATIONAL"
    Level_6="UNDEFINED"
    case "${New_Issue_Level}" in
    "NONE") New_Issue_Level_Num=0 ;;
    "CRITICAL") New_Issue_Level_Num=1 ;;
    "HIGH") New_Issue_Level_Num=2 ;;
    "MEDIUM") New_Issue_Level_Num=3 ;;
    "LOW") New_Issue_Level_Num=4 ;;
    "INFORMATIONAL") New_Issue_Level_Num=5 ;;
    "UNDEFINED") New_Issue_Level_Num=6 ;;
    *)
      Error="Error \: The value specified by -t is not supported. Enter one of the following values \[CRITICAL \| HIGH \| MEDIUM \| LOW | INFORMATIONAL \| UNDEFINED\]"
      return
      ;;
    esac
    ;;
    # https://github.com/goodwithtech/dockle#get-or-save-the-results-as-json
  "Dockle")
    Level_0="NONE"
    Level_1="FATAL"
    Level_2="WARN"
    Level_3="INFO"
    Level_4="SKIP"
    Level_5="PASS"
    case "${New_Issue_Level}" in
    "NONE") New_Issue_Level_Num=0 ;;
    "FATAL") New_Issue_Level_Num=1 ;;
    "WARN") New_Issue_Level_Num=2 ;;
    "INFO") New_Issue_Level_Num=3 ;;
    *)
      Error="Error \: The value specified by -t is not supported. Enter one of the following values \[FATAL \| WARN \| INFO\]"
      return
      ;;
    esac
    ;;
  *)
    Error="Error \: The value specified by -t is not supported. Enter one of the following values \[ECR_Image_Scan \| Dockle\]"
    return
    ;;
  esac
}

function getScanResult() {
  case "${Type}" in
  "ECR_Image_Scan") getEcrScanResult ;;
  "Dockle") getDockleScanResult ;;
  *)
    Error="Error : The value specified by -t is not supported. Enter one of the following values [ECR_Image_Scan | Dockle]"
    return
    ;;
  esac
}

function getEcrScanResult() {
  # ECRのイメージスキャン結果を20秒に一回取得しにいく、5回取得してもスキャン結果がCompleteにならない場合は処理を終了する。
  for i in $(seq 5); do
    Result=$(aws ecr describe-image-scan-findings --repository-name "${Repository}" \
      --image-id imageTag="${Image_tag}" --region "${AWS_DEFAULT_REGION}" \
      ${Profile} --output json | jq -r .)

    local scan_status=$(echo $Result | jq -r .imageScanStatus.status)

    if [ "x${scan_status}" = "xCOMPLETE" ]; then
      break
    fi

    if [ "x${i}" = "x5" ]; then
      Error="fail get image scan"
      return
    fi

    sleep 20s

  done

  Result_Summary="[${Type} Result : ${Env}_${Repository}]"

  for i in $(seq 1 6); do
    local level=$(eval echo '$'"Level_${i}")
    eval local "${level}_count"=$(echo ${Result} | jq -r .imageScanFindings.findingSeverityCounts."${level}")
    if [ "x$(eval echo '$'${level}_count)" = "xnull" ]; then
      continue
    fi
    Result_Summary="${Result_Summary} ${level} : $(eval echo '$'${level}_count)"
  done
}

function installDockle() {
  dockle_latest=$(
    curl --silent "https://api.github.com/repos/goodwithtech/dockle/releases/latest" |
      grep '"tag_name":' |
      sed -E 's/.*"v([^"]+)".*/\1/'
  )

  curl --silent -L -o dockle.deb https://github.com/goodwithtech/dockle/releases/download/v${dockle_latest}/dockle_${dockle_latest}_Linux-64bit.deb

  sudo dpkg -i dockle.deb

  rm dockle.deb
}

function getDockleScanResult() {
  # Dockleをインストール
  installDockle

  Result=$(dockle -f json ${Ecr_Registry}/${Repository}:${Image_tag} | grep -v "A new version")

  Result_Summary="[${Type} Result : ${Env}_${Repository}]"

  for i in $(seq 1 5); do
    local level=$(eval echo '$'"Level_${i}" | tr '[:upper:]' '[:lower:]')
    eval local "${level}_count"=$(echo ${Result} | jq -r .summary."${level}")
    if [ "x$(eval echo '$'${level}_count)" = "xnull" ]; then
      continue
    fi
    Result_Summary="${Result_Summary} ${level} : $(eval echo '$'${level}_count)"
  done
}

function newIssue() {
  # Issue管理対象のレベル以上の分だけ実行する。(ex.DockleでWARNを選択していたらFATALとWARNが実行される。)
  for i in $(seq 1 "${New_Issue_Level_Num}"); do
    local Level=$(eval echo '$'"Level_${i}")

    # issueにgrep後の対象が存在しない場合、cutコマンドが通らず、エラーになるため、set+eで回避する。
    set +e
    local Issue_severity_list=$(gh issue list | grep "\[${Type}\]${Env}_${Repository} ${Level}" | cut -f 3 | cut -f 3 -d " ")
    set -e

    # Issueに登録するTitleとBodyのリストを取得する。
    case "${Type}" in
    "ECR_Image_Scan")
      local severity_name_list=$(echo "${Result}" | jq -r --arg l "${Level}" '.imageScanFindings.findings[] | select(.severity == $l) | .name')
      local severity_detail_list=$(echo "${Result}" | jq -r --arg l "${Level}" '.imageScanFindings.findings[] | select(.severity == $l) | .uri')
      local count=$(echo ${Result} | jq -r .imageScanFindings.findingSeverityCounts.${Level})
      ;;
    "Dockle")
      local severity_name_list=$(echo "${Result}" | jq -r --arg l "${Level}" '.details[] | select(.level == $l) | .code')
      local severity_detail_list=$(echo "${Result}" | jq -r --arg l "${Level}" '.details[] | select(.level == $l) | .title')
      local lower_level=$(eval echo '$'"Level_${i}" | tr '[:upper:]' '[:lower:]')
      local count=$(echo ${Result} | jq -r .summary."${lower_level}")
      ;;
    *)
      Error="Error : The value specified by -t is not supported. Enter one of the following values [ECR_Image_Scan | Dockle]"
      return
      ;;
    esac

    if [ "x${count}" = "xnull" ]; then
      continue
    fi

    # 検知した脆弱性の数だけ実行する。
    for i in $(seq 1 ${count}); do
      local severity_name=$(echo "${severity_name_list}" | awk 'NR=='${i})
      local severity_detail=$(echo "${severity_detail_list}" | awk 'NR=='${i})
      local issue_title="[${Type}]${Env}_${Repository} ${Level} ${severity_name}"

      local check_known_issue=$(echo "${Issue_severity_list}" | grep "${severity_name}")
      if [ "x${check_known_issue}" = "x${severity_name}" ]; then
        continue
      fi

      gh issue create --title "${issue_title}" --body "${severity_detail}"
    done
  done
}

function closeIssue() {
  # Issue管理対象のレベル以上の分だけ実行する。(ex.DockleでWARNを選択していたらFATALとWARNが実行される。)
  for i in $(seq 1 "${New_Issue_Level_Num}"); do
    local Level=$(eval echo '$'"Level_${i}")

    set +e
    Updated_issue_severity_list=$(gh issue list | grep "\[${Type}\]${Env}_${Repository} ${Level}")
    set -e

    if [ "x${Updated_issue_severity_list}" = "x" ]; then
      continue
    fi

    # 検知した脆弱性のタイトルを取得する。
    case "${Type}" in
    "ECR_Image_Scan")
      local severity_name_list=$(echo "${Result}" | jq -r --arg l "${Level}" '.imageScanFindings.findings[] | select(.severity == $l) | .name')
      ;;
    "Dockle")
      local severity_name_list=$(echo "${Result}" | jq -r --arg l "${Level}" '.details[] | select(.level == $l) | .code')
      ;;
    *)
      Error="Error : The value specified by -t is not supported. Enter one of the following values [ECR_Image_Scan | Dockle]"
      return
      ;;
    esac

    local count=$(echo "${Updated_issue_severity_list}" | wc -l)

    # 登録されている該当レベルのIssueと今回検知した脆弱性を比較し、今回検知されなかったIssueをクローズする。
    for i in $(seq 1 ${count}); do
      set +e
      local issue_severity_number=$(echo "${Updated_issue_severity_list}" | awk 'NR=='${i} | cut -f 3 | cut -f 3 -d " ")
      local issue_number=$(echo "${Updated_issue_severity_list}" | awk 'NR=='${i} | cut -f 1)
      set -e

      local check_known_issue=$(echo "${severity_name_list}" | grep "${issue_severity_number}")

      if [ "x${check_known_issue}" = "x${issue_severity_number}" ]; then
        continue
      fi

      gh issue close "${issue_number}"

    done
  done
}

function main() {
  Error=""

  # 処理の種類を判定し、グローバル変数に必要な値をセットする。
  setProcessingTypeConfiguration

  if [ "x${Error}" != "x" ]; then
    echo "${Error}"
    exit 1
  fi

  # スキャンを実行し、スキャン結果のjson（$Result）と表示用の結果（$Result_Summary）を取得する。
  getScanResult

  if [ "x${Error}" != "x" ]; then
    echo "${Error}"
    exit 1
  fi

  echo $Result_Summary

  if [ "x${New_Issue_Level_Num}" == "x0" ]; then
    return
  fi

  # New_Issue_Levelで設定した脆弱性レベル以上のもので新規の検知があった場合、Issueに登録する。
  newIssue

  if [ "x${Error}" != "x" ]; then
    echo "${Error}"
    exit 1
  fi

  # 登録されているIssueの中で今回検知されなかったIssueをクローズする。
  closeIssue

  if [ "x${Error}" != "x" ]; then
    echo "${Error}"
    exit 1
  fi
}

# 直接ファイル指定で実行された時のみ、main functionを実行する。
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi

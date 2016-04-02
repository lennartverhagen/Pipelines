#!/usr/bin/env bash
set -e

# set defaults
args=""
BatchFolder=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd ) # folder where this script is stored
EnvironmentScript="${BatchFolder}/SetUpHCPPipeline.sh" # Pipeline environment script
StudyFolder="${HOME}/projects/Pipelines_ExampleData" # Location of subject folders (named by subject IDs in SubjList)
SubjList="100307" # Space delimited list of subject IDs
LogDir="./log"
runlocal="FALSE"

# parse the input arguments
for a in "$@" ; do
  case $a in
    --StudyFolder=*)  StudyFolder="${a#*=}"; shift ;;
    --SubjList=*)     SubjList="${a#*=}"; shift ;;
    --LogDir=*)       LogDir="${a#*=}"; shift ;;
    --runlocal)       runlocal="TRUE"; shift ;;
    *)                args="$args $a"; shift ;; # unsupported argument
  esac
done

# check if no redundant arguments have been set
if [[ -n $args ]] ; then
  >&2 echo ""; >&2 echo "unsupported arguments are given:" $args
  exit 1
fi

# Requirements for this script
#  installed versions of: FSL (version 5.0.6), FreeSurfer (version 5.3.0-HCP), gradunwarp (HCP version 1.0.2) if doing gradient distortion correction
#  environment: FSLDIR , FREESURFER_HOME , HCPPIPEDIR , CARET7DIR , PATH (for gradient_unwarp.py)

# Set up pipeline environment variables and software
. ${EnvironmentScript}

# Log the originating call
echo "$@"

#if [[ -n $SGE_ROOT ]] ; then
    QUEUE="-q veryshort.q"
    #QUEUE="-q hcp_priority.q"
#fi

PRINTCOM=""
#PRINTCOM="echo"

# set the cluster queuing or local execution command
if [[ $runlocal == TRUE ]] ; then
    echo "About to run ${HCPPIPEDIR}/PreFreeSurfer/PreFreeSurferPipeline.sh"
    queuing_command=""
else
    echo "About to use fsl_sub to queue or run ${HCPPIPEDIR}/PreFreeSurfer/PreFreeSurferPipeline.sh"
    mkdir -p $LogDir # ensure the directory to store fsl_sub logfiles exists
    queuing_command="${FSLDIR}/bin/fsl_sub ${QUEUE} -l $LogDir"
fi


########################################## INPUTS ##########################################

#Scripts called by this script do assume they run on the outputs of the FreeSurfer Pipeline

######################################### DO WORK ##########################################

# Naming Conventions
T1wFolder="T1w"
T2wFolder="T2w"
statsFolder="stats"
ACPCFolder="ACPCAlignment"
BiasFolder="BiasFieldCorrection_*"
BrainFolder="BrainExtraction_*"
FSAverageLink="fsaverage"
FSLHAverageLink="lh.EC_average"
FSRHAverageLink="rh.EC_average"
AtlasSpaceFolder="MNINonLinear"
ResultsFolder="Results"
xfmsFolder="xfms"
Files2Remove=("*_1mm" "T1w_acpc_brain_mask" "T1w_acpc_brain" "T1w_acpc" "*_gdc")

for Subject in $SubjList ; do
  echo $Subject

  # Subject specific naming conventions
  SubjT1w="$StudyFolder"/"$Subject"/"$T1wFolder"
  SubjT2w="$StudyFolder"/"$Subject"/"$T2wFolder"
  SubjFS="$SubjT1w"/"${Subject}"
  SubjAtlas="$StudyFolder"/"$Subject"/"$AtlasSpaceFolder"
  SubjFiles2Remove="${Files2Remove[@]/#/$SubjT1w/}"
  SubjTmpFS=$(mktemp -d "${SubjT1w}/tmp.FS.XXXXXXXXXX")
  SubjTmpxfms=$(mktemp -d "${SubjAtlas}/tmp.xfms.XXXXXXXXXX")

  if [ -n "${command_line_specified_run_local}" ] ; then
      echo "About to run clean-up after ${HCPPIPEDIR}/PostFreeSurfer/PostFreeSurferPipeline.sh"
      queuing_command="exec"
  else
      echo "About to use fsl_sub to queue or clean-up after ${HCPPIPEDIR}/PostFreeSurfer/PostFreeSurferPipeline.sh"
      queuing_command="${FSLDIR}/bin/fsl_sub ${QUEUE}"
  fi

  # create a tempfile to submit multiple commands
  TmpFile=$(mktemp "$(pwd)/tmp.$(basename $0).cleanup.XXXXXXXXXX")
  chmod +x $TmpFile

  # write the commands to the tempfile
  echo -n "rm -rf ${SubjT2w}; " >> $TmpFile
  echo -n "rm -rf ${SubjT1w}/${ACPCFolder}; " >> $TmpFile
  echo -n "rm -rf ${SubjT1w}/${BiasFolder}; " >> $TmpFile
  echo -n "rm -rf ${SubjT1w}/${BrainFolder}; " >> $TmpFile
  echo -n "rm -f ${SubjT1w}/${FSAverageLink}; " >> $TmpFile
  echo -n "rm -f ${SubjT1w}/${FSLHAverageLink}; " >> $TmpFile
  echo -n "rm -f ${SubjT1w}/${FSRHAverageLink}; " >> $TmpFile
  echo -n "mv -f ${SubjFS}/${statsFolder} ${SubjTmpFS}/${statsFolder}; " >> $TmpFile
  echo -n "rm -rf ${SubjFS}; " >> $TmpFile
  echo -n "mv -f ${SubjTmpFS} ${SubjFS}; " >> $TmpFile
  echo -n "$FSLDIR/bin/imrm ${SubjFiles2Remove}; " >> $TmpFile
  echo -n "rm -rf ${SubjAtlas}/${ResultsFolder}; " >> $TmpFile
  echo -n "$FSLDIR/bin/immv ${SubjAtlas}/${xfmsFolder}/acpc_dc2standard ${SubjTmpxfms}/acpc_dc2standard; " >> $TmpFile
  echo -n "$FSLDIR/bin/immv ${SubjAtlas}/${xfmsFolder}/standard2acpc_dc ${SubjTmpxfms}/standard2acpc_dc; " >> $TmpFile
  echo -n "$FSLDIR/bin/immv ${SubjAtlas}/${xfmsFolder}/NonlinearRegJacobians ${SubjTmpxfms}/NonlinearRegJacobians; " >> $TmpFile
  echo -n "rm -rf ${SubjAtlas}/${xfmsFolder}; " >> $TmpFile
  echo -n "mv -f ${SubjTmpxfms} ${SubjAtlas}/${xfmsFolder}; " >> $TmpFile
  echo -n "rm -f $TmpFile; " >> $TmpFile

  # submit or execute the tempfile
  ${queuing_command} $TmpFile

done

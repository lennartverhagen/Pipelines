#!/bin/bash

get_batch_options() {
    local arguments=($@)

    unset command_line_specified_study_folder
    unset command_line_specified_subj_list
    unset command_line_specified_scanner
    unset command_line_specified_run_local

    local index=0
    local numArgs=${#arguments[@]}
    local argument

    while [ ${index} -lt ${numArgs} ]; do
        argument=${arguments[index]}

        case ${argument} in
            --StudyFolder=*)
                command_line_specified_study_folder=${argument/*=/""}
                index=$(( index + 1 ))
                ;;
            --SubjList=*)
                command_line_specified_subj_list=${argument/*=/""}
                index=$(( index + 1 ))
                ;;
            --Scanner=*)
                command_line_specified_scanner=${argument/*=/""}
                index=$(( index + 1 ))
                ;;
            --runlocal)
                command_line_specified_run_local="TRUE"
                index=$(( index + 1 ))
                ;;
	    *)
		echo ""
		echo "ERROR: Unrecognized Option: ${argument}"
		echo ""
		exit 1
		;;
        esac
    done
}

get_batch_options $@

StudyFolder="${HOME}/projects/Pipelines_ExampleData" #Location of Subject folders (named by subjectID)
Subjlist="100307" #Space delimited list of subject IDs
BatchFolder=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )
EnvironmentScript="${BatchFolder}/SetUpHCPPipeline.sh" #Pipeline environment script
Scanner="3T" # Scanner specific subfolder of unprocessed MR data, usually either 3T or 7T

if [ -n "${command_line_specified_study_folder}" ]; then
    StudyFolder="${command_line_specified_study_folder}"
fi

if [ -n "${command_line_specified_subj_list}" ]; then
  # replace all "@" with " "
  command_line_specified_subj_list="${command_line_specified_subj_list//@/ }"
  # overwrite default with user specified value
  Subjlist="${command_line_specified_subj_list}"
fi

if [ -n "${command_line_specified_scanner}" ]; then
    Scanner="${command_line_specified_scanner}"
fi

# Requirements for this script
#  installed versions of: FSL (version 5.0.6), FreeSurfer (version 5.3.0-HCP), gradunwarp (HCP version 1.0.2) if doing gradient distortion correction
#  environment: FSLDIR , FREESURFER_HOME , HCPPIPEDIR , CARET7DIR , PATH (for gradient_unwarp.py)

# Set up pipeline environment variables and software
. ${EnvironmentScript}

# Log the originating call
echo "$@"

#if [ X$SGE_ROOT != X ] ; then
    QUEUE="-q long.q"
    #QUEUE="-q hcp_priority.q"
#fi

PRINTCOM=""
#PRINTCOM="echo"
#QUEUE="-q veryshort.q"


########################################## INPUTS ##########################################

# Scripts called by this script do NOT assume anything about the form of the input names or paths.
# This batch script assumes the HCP raw data naming convention, e.g.
#
#	${StudyFolder}/${Subject}/unprocessed/${Scanner}/T1w_MPR1/${Subject}_${Scanner}_T1w_MPR1.nii.gz
#	${StudyFolder}/${Subject}/unprocessed/${Scanner}/T1w_MPR2/${Subject}_${Scanner}_T1w_MPR2.nii.gz
#
#	${StudyFolder}/${Subject}/unprocessed/${Scanner}/T2w_SPC1/${Subject}_${Scanner}_T2w_SPC1.nii.gz
#	${StudyFolder}/${Subject}/unprocessed/${Scanner}/T2w_SPC2/${Subject}_${Scanner}_T2w_SPC2.nii.gz
#
#	${StudyFolder}/${Subject}/unprocessed/${Scanner}/T1w_MPR1/${Subject}_${Scanner}_FieldMap_Magnitude.nii.gz
#	${StudyFolder}/${Subject}/unprocessed/${Scanner}/T1w_MPR1/${Subject}_${Scanner}_FieldMap_Phase.nii.gz

# Change Scan Settings: Sample Spacings, and $UnwarpDir to match your images
# These are set to match the HCP Protocol by default
#
# Readout Distortion Correction:
#
#   You have the option of using either gradient echo field maps or spin echo field maps to
#   perform readout distorction correction on your structural images, or not to do readout
#   distortion correction at all.
#
#   The HCP Pipeline Scripts currently support the use of gradient echo field maps or spin echo
#   field maps as they are produced by the Siemens Connectom Scanner. They also support the
#   use of gradient echo field maps as generated by General Electric scanners.
#
#   Change either the gradient echo field map or spin echo field map scan settings to match
#   your data. This script is setup to use gradient echo field maps from the Siemens Connectom
#   Scanner using the HCP Protocol.
#
# Gradient Distortion Correction:
#
#   If using gradient distortion correction, use the coefficents from your scanner.
#   The HCP gradient distortion coefficents are only available through Siemens
#   Gradient distortion in standard scanners like the Trio is much less than for the HCP Skyra.


######################################### DO WORK ##########################################


for Subject in $Subjlist ; do
  echo $Subject

  # Input Images
  # Detect Number of T1w Images
  numT1ws=`ls ${StudyFolder}/${Subject}/unprocessed/${Scanner} | grep T1w_MPR | wc -l`
  echo "Found ${numT1ws} T1w Images for subject ${Subject}"
  T1wInputImages=""
  i=1
  while [ $i -le $numT1ws ] ; do
    T1wInputImages=`echo "${T1wInputImages}${StudyFolder}/${Subject}/unprocessed/${Scanner}/T1w_MPR${i}/${Subject}_${Scanner}_T1w_MPR${i}.nii.gz@"`
    i=$(($i+1))
  done

  # Detect Number of T2w Images
  numT2ws=`ls ${StudyFolder}/${Subject}/unprocessed/${Scanner} | grep T2w_SPC | wc -l`
  echo "Found ${numT2ws} T2w Images for subject ${Subject}"
  T2wInputImages=""
  i=1
  while [ $i -le $numT2ws ] ; do
    T2wInputImages=`echo "${T2wInputImages}${StudyFolder}/${Subject}/unprocessed/${Scanner}/T2w_SPC${i}/${Subject}_${Scanner}_T2w_SPC${i}.nii.gz@"`
    i=$(($i+1))
  done

  # Readout Distortion Correction:
  #
  #   Currently supported Averaging and readout distortion correction methods:
  #   (i.e. supported values for the AvgrdcSTRING variable in this script and the
  #   --avgrdcmethod= command line option for the PreFreeSurferPipeline.sh script.)
  #
  #   "NONE"
  #     Average any repeats but do no readout distortion correction
  #
  #   "FIELDMAP"
  #     This value is equivalent to the "SiemensFieldMap" value described below.
  #     Use of the "SiemensFieldMap" value is prefered, but "FIELDMAP" is
  #     included for backward compatibility with the versions of these
  #     scripts that only supported use of Siemens-specific Gradient Echo
  #     Field Maps and did not support Gradient Echo Field Maps from any
  #     other scanner vendor.
  #
  #   "TOPUP"
  #     Average any repeats and use Spin Echo Field Maps for readout distortion
  #     correction
  #
  #   "GeneralElectricFieldMap"
  #     Average any repeats and use General Electric specific Gradient Echo
  #     Field Map for readout distortion correction
  #
  #   "SiemensFieldMap"
  #     Average any repeats and use Siemens specific Gradient Echo Field Maps
  #     for readout distortion correction

  #
  # Current Setup is for Siemens specific Gradient Echo Field Maps
  #
  #   The following settings for AvgrdcSTRING, MagnitudeInputName, PhaseInputName,
  #   and TE are for using the Siemens specific Gradient Echo Field Maps that are
  #   collected and used in the standard HCP protocol.
  #
  #   Note: The AvgrdcSTRING variable could also be set to the value "FIELDMAP"
  #         which is equivalent to "SiemensFieldMap".
  AvgrdcSTRING="SiemensFieldMap"

  # ------------------------------------------------------------------------
  #   Variables related to using Siemens specific Gradient Echo Field Maps
  # ------------------------------------------------------------------------

  # The MagnitudeInputName variable should be set to a 4D magitude volume
  # with two 3D timepoints or "NONE" if not used
  MagnitudeInputName="${StudyFolder}/${Subject}/unprocessed/${Scanner}/T1w_MPR1/${Subject}_${Scanner}_FieldMap_Magnitude.nii.gz"

  # The PhaseInputName variable should be set to a 3D phase difference volume
  # or "NONE" if not used
  PhaseInputName="${StudyFolder}/${Subject}/unprocessed/${Scanner}/T1w_MPR1/${Subject}_${Scanner}_FieldMap_Phase.nii.gz"

  # Test for the existance of the Gradient Echo Fieldmap images
  UseGradEchoFieldmap="TRUE"
  [[ ! -r $MagnitudeInputName ]] || [[ ! -r $PhaseInputName ]] && UseGradEchoFieldmap="FALSE"

  # The TE variable should be set to 2.46ms for 3T scanner, 1.02ms for 7T
  # scanner or "NONE" if not using
  if [[ $Scanner = "3T" ]] ; then
    TE="2.46"
  elif [[ $Scanner = "7T" ]] ; then
    TE="1.02"
  fi

  if [[ $UseGradEchoFieldmap = "FALSE" ]] ; then
    MagnitudeInputName="NONE"
    PhaseInputName="NONE"
    TE="NONE"
  fi

  # ---------------------------------------------------
  #   Variables related to using Spin Echo Field Maps
  # ---------------------------------------------------

  # The following variables would be set to values other than "NONE" for
  # using Spin Echo Field Maps (i.e. when AvgrdcSTRING="TOPUP")

  # The SpinEchoPhaseEncodeNegative variable should be set to the
  # spin echo field map volume with a negative phase encoding direction
  # (LR in 3T HCP data, AP in 7T HCP data), and set to "NONE" if not
  # using Spin Echo Field Maps (i.e. if AvgrdcSTRING is not equal to "TOPUP")
  #
  # Example values for when using Spin Echo Field Maps:
  #   ${StudyFolder}/${Subject}/unprocessed/${Scanner}/T1w_MPR1/${Subject}_${Scanner}_SpinEchoFieldMap_LR.nii.gz
  #   ${StudyFolder}/${Subject}/unprocessed/${Scanner}/T1w_MPR1/${Subject}_${Scanner}_SpinEchoFieldMap_AP.nii.gz
  SpinEchoPhaseEncodeNegative="NONE"

  # The SpinEchoPhaseEncodePositive variable should be set to the
  # spin echo field map volume with positive phase encoding direction
  # (RL in 3T HCP data, PA in 7T HCP data), and set to "NONE" if not
  # using Spin Echo Field Maps (i.e. if AvgrdcSTRING is not equal to "TOPUP")
  #
  # Example values for when using Spin Echo Field Maps:
  #   ${StudyFolder}/${Subject}/unprocessed/${Scanner}/T1w_MPR1/${Subject}_${Scanner}_SpinEchoFieldMap_RL.nii.gz
  #   ${StudyFolder}/${Subject}/unprocessed/${Scanner}/T1w_MPR1/${Subject}_${Scanner}_SpinEchoFieldMap_PA.nii.gz
  SpinEchoPhaseEncodePositive="NONE"

  # Echo Spacing or Dwelltime of spin echo EPI MRI image. Specified in seconds.
  # Set to "NONE" if not used.
  #
  # Dwelltime = 1/(BandwidthPerPixelPhaseEncode * # of phase encoding samples)
  # DICOM field (0019,1028) = BandwidthPerPixelPhaseEncode
  # DICOM field (0051,100b) = AcquisitionMatrixText first value (# of phase encoding samples).
  # On Siemens, iPAT/GRAPPA factors have already been accounted for.
  #
  # Example value for when using Spin Echo Field Maps:
  #   0.000580002668012
  DwellTime="NONE"

  # Spin Echo Unwarping Direction
  # x or y (minus or not does not matter)
  # "NONE" if not used
  #
  # Example values for when using Spin Echo Field Maps: x, -x, y, -y
  # Note: +x or +y are not supported. For positive values, do not include the + sign
  SEUnwarpDir="NONE"

  # Topup Configuration file
  # "NONE" if not used
  TopupConfig="NONE"

  # ---------------------------------------------------------------------------------
  #   Variables related to using General Electric specific Gradient Echo Field Maps
  # ---------------------------------------------------------------------------------

  # The following variables would be set to values other than "NONE" for
  # using General Electric specific Gradient Echo Field Maps (i.e. when
  # AvgrdcSTRING="GeneralElectricFieldMap")

  # Example value for when using General Electric Gradient Echo Field Map
  #
  # GEB0InputName should be a General Electric style B0 fielmap with two volumes
  #   1) fieldmap in deg and
  #   2) magnitude,
  # set to NONE if using TOPUP or FIELDMAP/SiemensFieldMap
  #
  #   GEB0InputName="${StudyFolder}/${Subject}/unprocessed/${Scanner}/T1w_MPR1/${Subject}_${Scanner}_GradientEchoFieldMap.nii.gz"
  GEB0InputName="NONE"

  # Templates
  T1wTemplate="${HCPPIPEDIR_Templates}/MNI152_T1_0.7mm.nii.gz" #Hires T1w MNI template
  T1wTemplateBrain="${HCPPIPEDIR_Templates}/MNI152_T1_0.7mm_brain.nii.gz" #Hires brain extracted MNI template
  T1wTemplate2mm="${HCPPIPEDIR_Templates}/MNI152_T1_2mm.nii.gz" #Lowres T1w MNI template
  T2wTemplate="${HCPPIPEDIR_Templates}/MNI152_T2_0.7mm.nii.gz" #Hires T2w MNI Template
  T2wTemplateBrain="${HCPPIPEDIR_Templates}/MNI152_T2_0.7mm_brain.nii.gz" #Hires T2w brain extracted MNI Template
  T2wTemplate2mm="${HCPPIPEDIR_Templates}/MNI152_T2_2mm.nii.gz" #Lowres T2w MNI Template
  TemplateMask="${HCPPIPEDIR_Templates}/MNI152_T1_0.7mm_brain_mask.nii.gz" #Hires MNI brain mask template
  Template2mmMask="${HCPPIPEDIR_Templates}/MNI152_T1_2mm_brain_mask_dil.nii.gz" #Lowres MNI brain mask template

  # Structural Scan Settings (set all to NONE if not doing readout distortion correction)
  #
  # Sample values for when using General Electric Gradient Echo Field Maps
  #   T1wSampleSpacing="0.000011999" # For General Electric scanners, 1/((0018,0095)*(0028,0010))
  #   T2wSampleSpacing="0.000008000" # For General Electric scanners, 1/((0018,0095)*(0028,0010))
  #   UnwarpDir="y"
  #
  # The values set below are for the HCP Protocol using the Siemens Connectom Scanner
  T1wSampleSpacing="0.0000074" #DICOM field (0019,1018) in s or "NONE" if not used
  T2wSampleSpacing="0.0000021" #DICOM field (0019,1018) in s or "NONE" if not used
  UnwarpDir="z" # z appears to be best for Siemens Gradient Echo Field Maps or "NONE" if not used
  # The values below are example values for the FMRIB 7T (commented out)
  #T1wSampleSpacing="0.00001627604167"
  #T2wSampleSpacing="0.00000500160051"
  #UnwarpDir="y-" # y- refers to A>>P

  if [[ $UseGradEchoFieldmap = "FALSE" ]] ; then
    T1wSampleSpacing="NONE"
    T2wSampleSpacing="NONE"
    UnwarpDir="NONE"
  fi

  # Config settings of the "Oxford Structural" fork
  InitBiasCorr="TRUE" # perform initial bias correct to improve registration ("TRUE", "FALSE")
  BiasCorr="FAST" # method for actual bias correction (after registration) set to "sqrtT1wbyT2w" for HCP default, or set to "FAST" to use RobustBiasCorr.sh based on fsl_anat and fast
  if [[ $Scanner = "7T" ]] ; then
    MaskArtery="TRUE" # mask arteries in registration and bias correction (important for 7T data) ("TRUE", "FALSE")
  else
    MaskArtery="FALSE"
  fi
  SmoothFillNonPos="TRUE" # smoothly fill negative and exactly zero values in images (after spline interpolation) ("TRUE", "FALSE")

  # Other Config Settings
  BrainSize="150" #BrainSize in mm, 150 for humans
  FNIRTConfig="${HCPPIPEDIR_Config}/T1_2_MNI152_2mm.cnf" #FNIRT 2mm T1w Config

  # GradientDistortionCoeffs="${HCPPIPEDIR_Config}/coeff_SC72C_Skyra.grad" #Location of Coeffs file or "NONE" to skip
  GradientDistortionCoeffs="NONE" # Set to NONE to skip gradient distortion correction

  if [ -n "${command_line_specified_run_local}" ] ; then
      echo "About to run ${HCPPIPEDIR}/PreFreeSurfer/PreFreeSurferPipeline.sh"
      queuing_command=""
  else
      echo "About to use fsl_sub to queue or run ${HCPPIPEDIR}/PreFreeSurfer/PreFreeSurferPipeline.sh"
      queuing_command="${FSLDIR}/bin/fsl_sub ${QUEUE}"
  fi

  ${queuing_command} ${HCPPIPEDIR}/PreFreeSurfer/PreFreeSurferPipeline.sh \
      --path="$StudyFolder" \
      --subject="$Subject" \
      --t1="$T1wInputImages" \
      --t2="$T2wInputImages" \
      --t1template="$T1wTemplate" \
      --t1templatebrain="$T1wTemplateBrain" \
      --t1template2mm="$T1wTemplate2mm" \
      --t2template="$T2wTemplate" \
      --t2templatebrain="$T2wTemplateBrain" \
      --t2template2mm="$T2wTemplate2mm" \
      --templatemask="$TemplateMask" \
      --template2mmmask="$Template2mmMask" \
      --brainsize="$BrainSize" \
      --fnirtconfig="$FNIRTConfig" \
      --fmapmag="$MagnitudeInputName" \
      --fmapphase="$PhaseInputName" \
      --fmapgeneralelectric="$GEB0InputName" \
      --echodiff="$TE" \
      --SEPhaseNeg="$SpinEchoPhaseEncodeNegative" \
      --SEPhasePos="$SpinEchoPhaseEncodePositive" \
      --echospacing="$DwellTime" \
      --seunwarpdir="$SEUnwarpDir" \
      --t1samplespacing="$T1wSampleSpacing" \
      --t2samplespacing="$T2wSampleSpacing" \
      --unwarpdir="$UnwarpDir" \
      --gdcoeffs="$GradientDistortionCoeffs" \
      --avgrdcmethod="$AvgrdcSTRING" \
      --topupconfig="$TopupConfig" \
      --initbiascorr="$InitBiasCorr" \
      --biascorr="$BiasCorr" \
      --maskartery="$MaskArtery" \
      --smoothfillnonpos="$SmoothFillNonPos" \
      --printcom=$PRINTCOM

  # The following lines are used for interactive debugging to set the positional parameters: $1 $2 $3 ...

  echo "set -- --path=${StudyFolder} \
      --subject=${Subject} \
      --t1=${T1wInputImages} \
      --t2=${T2wInputImages} \
      --t1template=${T1wTemplate} \
      --t1templatebrain=${T1wTemplateBrain} \
      --t1template2mm=${T1wTemplate2mm} \
      --t2template=${T2wTemplate} \
      --t2templatebrain=${T2wTemplateBrain} \
      --t2template2mm=${T2wTemplate2mm} \
      --templatemask=${TemplateMask} \
      --template2mmmask=${Template2mmMask} \
      --brainsize=${BrainSize} \
      --fnirtconfig=${FNIRTConfig} \
      --fmapmag=${MagnitudeInputName} \
      --fmapphase=${PhaseInputName} \
      --fmapgeneralelectric=${GEB0InputName} \
      --echodiff=${TE} \
      --SEPhaseNeg=${SpinEchoPhaseEncodeNegative} \
      --SEPhasePos=${SpinEchoPhaseEncodePositive} \
      --echospacing=${DwellTime} \
      --seunwarpdir=${SEUnwarpDir} \
      --t1samplespacing=${T1wSampleSpacing} \
      --t2samplespacing=${T2wSampleSpacing} \
      --unwarpdir=${UnwarpDir} \
      --gdcoeffs=${GradientDistortionCoeffs} \
      --avgrdcmethod=${AvgrdcSTRING} \
      --topupconfig=${TopupConfig} \
      --initbiascorr=${InitBiasCorr} \
      --biascorr=${BiasCorr} \
      --maskartery=${MaskArtery} \
      --smoothfillnonpos=${SmoothFillNonPos} \
      --printcom=${PRINTCOM}"

  echo ". ${EnvironmentScript}"

done

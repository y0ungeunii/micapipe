#!/bin/bash
#
# DWI structural processing with bash:
#
# Preprocessing workflow for diffusion MRI.
#
# This workflow makes use of freesurfer, FastSurfer, FSL, ANTs, and workbench
#
# Atlas an templates are avaliable from:
#
# https://github.com/MICA-MNI/micaopen/templates
#
#   ARGUMENTS order:
#   $1 : BIDS directory
#   $2 : participant
#   $3 : Out Directory
#
BIDS=$1
id=$2
out=$3
SES=$4
nocleanup=$5
threads=$6
tmpDir=$7
atlas=$8
FastSurfer=$9
PROC=${10}
export OMP_NUM_THREADS=$threads
here=$(pwd)

#------------------------------------------------------------------------------#
# qsub configuration
if [ "$PROC" = "qsub-MICA" ] || [ "$PROC" = "qsub-all.q" ];then
    export MICAPIPE=/data_/mica1/01_programs/micapipe-v0.2.0
    source "${MICAPIPE}/functions/init.sh" "$threads"
fi

# source utilities
source $MICAPIPE/functions/utilities.sh

# Assigns variables names
bids_variables "$BIDS" "$id" "$out" "$SES"

# Setting Surface Directory
Nrecon=($(ls "${dir_QC}/${idBIDS}_module-proc_surf-"*.json 2>/dev/null | wc -l))
if [[ "$Nrecon" -lt 1 ]]; then
  Error "Subject $id doesn't have a module-proc_surf: run -proc_surf"; exit 1
elif [[ "$Nrecon" -eq 1 ]]; then
  module_qc=$(ls "${dir_QC}/${idBIDS}_module-proc_surf-"*.json 2>/dev/null)
  recon="$(echo ${module_qc/.json/} | awk -F 'proc_surf-' '{print $2}')"
elif [[ "$Nrecon" -gt 1 ]]; then
  Warning "${idBIDS} has been processed with freesurfer and fastsurfer."
  if [[ "$FastSurfer" == "TRUE" ]]; then
    Note "fastsurfer will run: $FastSurfer\n"; recon="fastsurfer";
  else
    Note "freesurfer is the default"; recon="freesurfer"
  fi
fi
# Set surface directory
set_surface_directory "${recon}"

# Check dependencies Status: PROC_SURF
micapipe_check_dependency "proc_surf" "${dir_QC}/${idBIDS}_module-proc_surf-${recon}.json"

# Manage manual inputs: Parcellations
cd "$util_parcelations"
if [[ "$atlas" == "DEFAULT" ]]; then
  atlas_parc=($(ls lh.*annot))
  Natlas="${#atlas_parc[*]}"
  Info "Selected parcellations: DEFAULT, N=${Natlas}"
else
  IFS=',' read -ra atlas_parc <<< "$atlas"
  for i in "${!atlas_parc[@]}"; do atlas_parc[i]=$(ls lh."${atlas_parc[$i]}"_mics.annot 2>/dev/null); done
  atlas_parc=("${atlas_parc[@]}")
  Natlas="${#atlas_parc[*]}"
  Info "Selected parcellations: $atlas, N=${Natlas}"
fi
cd "$here"

# Check inputs: Nativepro T1
if [ "${Natlas}" -eq 0 ]; then
  Error "Provided -atlas do not match with any on MICAPIPE, try one of the following list:
\t\taparc-a2009s,aparc,economo,glasser-360
\t\tschaefer-1000,schaefer-100,schaefer-200
\t\tschaefer-300,schaefer-400,schaefer-500
\t\tschaefer-600,schaefer-700,schaefer-800
\t\tschaefer-900,vosdewael-100,vosdewael-200
\t\tvosdewael-300,vosdewael-400"; exit
fi

# Check inputs: Nativepro T1
if [ ! -f "${proc_struct}/${idBIDS}"_space-nativepro_T1w.nii.gz ]; then Error "Subject $id doesn't have T1_nativepro"; exit; fi
if [ ! -f "$T1fast_seg" ]; then Error "Subject $id doesn't have FAST: run -proc_structural"; exit; fi
# Check inputs: surface space T1
if [ ! -f "$T1surf" ]; then Error "Subject $id doesn't have a T1 on surface space: re-run -proc_surf"; exit; fi
if [ ! -f "${dir_subjsurf}/mri/T1.mgz" ]; then Error "Subject $id doesn't have a mri/ribbon.mgz: re-run -proc_surf"; exit; fi

# End if module has been processed
module_json="${dir_QC}/${idBIDS}_module-post_structural.json"
micapipe_check_json_status "${module_json}" "post_structural"

#------------------------------------------------------------------------------#
Title "POST-structural processing\n\t\tmicapipe $Version, $PROC "
micapipe_software
# print the names on the terminal
bids_print.variables-post

# GLOBAL variables for this script
Note "Saving temporal dir:" "${nocleanup}"
Note "ANTs threads:" "$threads"
Note "wb_command threads:" "${OMP_NUM_THREADS}"
Note "Surface software:" "${recon}"

#	Timer
aloita=$(date +%s)
Nsteps=0
N=0

# Create script specific temp directory
tmp=${tmpDir}/${RANDOM}_micapipe_post-struct_${idBIDS}
Do_cmd mkdir -p "$tmp"

# TRAP in case the script fails
trap 'cleanup $tmp $nocleanup $here' SIGINT SIGTERM

# Freesurface SUBJECTs directory
export SUBJECTS_DIR=${dir_surf}

#------------------------------------------------------------------------------#
# Compute affine matrix from surface space to nativepro
T1_in_fs=${tmp}/T1.nii.gz
T1_fsnative=${proc_struct}/${idBIDS}_space-fsnative_T1w.nii.gz
mat_fsnative_affine=${dir_warp}/${idBIDS}_from-fsnative_to_nativepro_T1w_
T1_fsnative_affine=${mat_fsnative_affine}0GenericAffine.mat

if [[ ! -f "$T1_fsnative" ]] || [[ ! -f "$T1_fsnative_affine" ]]; then ((N++))
    Do_cmd mrconvert "$T1surf" "$T1_in_fs"
    Do_cmd antsRegistrationSyN.sh -d 3 -f "$T1nativepro" -m "$T1_in_fs" -o "$mat_fsnative_affine" -t a -n "$threads" -p d
    Do_cmd antsApplyTransforms -d 3 -i "$T1nativepro" -r "$T1_in_fs" -t ["${T1_fsnative_affine}",1] -o "$T1_fsnative" -v -u int
    if [[ -f ${T1_fsnative} ]]; then ((Nsteps++)); fi
    post_struct_transformations "$T1nativepro" "$T1_fsnative" "${dir_warp}/${idBIDS}_transformations-post_structural.json" '${T1_fsnative_affine}'
else
    Info "Subject ${id} has a T1 on Surface space"; ((Nsteps++)); ((N++))
fi

#------------------------------------------------------------------------------#
# Create parcellation on nativepro space
Info "fsaverage5 annnot parcellations to T1-nativepro Volume"
# Variables
T1str_nat="${idBIDS}_space-nativepro_T1w_atlas"
T1str_fs="${idBIDS}_space-fsnative_T1w"
cd "$util_parcelations"
for parc in "${atlas_parc[@]}"; do
    parc_annot="${parc/lh./}"
    parc_str=$(echo "${parc_annot}" | awk -F '_mics' '{print $1}')
    if [[ ! -f "${dir_volum}/${T1str_nat}-${parc_str}.nii.gz" ]]; then ((N++))
        for hemi in lh rh; do
        Info "Running surface $hemi $parc_annot to $subject"
        Do_cmd mri_surf2surf --hemi "$hemi" \
               		  --srcsubject fsaverage5 \
               		  --trgsubject "$idBIDS" \
               		  --sval-annot "${hemi}.${parc_annot}" \
               		  --tval "${dir_subjsurf}/label/${hemi}.${parc_annot}"
        done
        fs_mgz="${tmp}/${parc_str}.mgz"
        fs_tmp="${tmp}/${parc_str}_in_T1.mgz"
        fs_nii="${tmp}/${T1str_fs}_${parc_str}.nii.gz"                   # labels in fsnative tmp dir
        labels_nativepro="${dir_volum}/${T1str_nat}-${parc_str}.nii.gz"  # lables in nativepro

        # Register the annot surface parcelation to the T1-surface volume
        Do_cmd mri_aparc2aseg --s "$idBIDS" --o "$fs_mgz" --annot "${parc_annot/.annot/}" --new-ribbon
        Do_cmd mri_label2vol --seg "$fs_mgz" --temp "$T1surf" --o "$fs_tmp" --regheader "${dir_subjsurf}/mri/aseg.mgz"
        Do_cmd mrconvert "$fs_tmp" "$fs_nii" -force      # mgz to nifti_gz
        Do_cmd fslreorient2std "$fs_nii" "$fs_nii"       # reorient to standard
        Do_cmd fslmaths "$fs_nii" -thr 1000 "$fs_nii"    # threshold the labels

        # Register parcellation to nativepro
        Do_cmd antsApplyTransforms -d 3 -i "$fs_nii" -r "$T1nativepro" -n GenericLabel -t "$T1_fsnative_affine" -o "$labels_nativepro" -v -u int
        if [[ -f "$labels_nativepro" ]]; then ((Nsteps++)); fi
    else
        Info "Subject ${id} has a ${parc_str} segmentation on T1-nativepro space"
        ((Nsteps++)); ((N++))
    fi
done
Do_cmd rm -rf ${dir_warp}/*Warped.nii.gz 2>/dev/null

#------------------------------------------------------------------------------#
# Compute warp of native structural to surface and apply to 5TT and first
if [[ ! -f "${dir_conte69}/${idBIDS}_hemi-R_surf-fsLR-32k_space-fsnative_label-midthickness.surf.gii" ]]; then
    for hemisphere in l r; do
      Info "Native surfaces to conte69-64k vertices (${hemisphere}h hemisphere)"
      HEMICAP=$(echo $hemisphere | tr [:lower:] [:upper:])
      surf_id=${idBIDS}_hemi-${HEMICAP}_surf
        # Build the fsLR-32k sphere and midthickness surface
        Do_cmd wb_shortcuts -freesurfer-resample-prep \
            "${dir_subjsurf}/surf/${hemisphere}h.white" \
            "${dir_subjsurf}/surf/${hemisphere}h.pial" \
            "${dir_subjsurf}/surf/${hemisphere}h.sphere.reg" \
            "${util_surface}/fs_LR-deformed_to-fsaverage.${HEMICAP}.sphere.32k_fs_LR.surf.gii" \
            "${dir_subjsurf}/surf/${hemisphere}h.midthickness.surf.gii" \
            "${dir_conte69}/${surf_id}-fsLR-32k_space-fsnative_label-midthickness.surf.gii" \
            "${dir_conte69}/${surf_id}-fsnative_label-sphere.surf.gii"
        # Resample white and pial surfaces to fsLR-32k
        for surface in pial white; do ((N++))
            Do_cmd mris_convert "${dir_subjsurf}/surf/${hemisphere}h.${surface}" "${tmp}/${hemisphere}h.${surface}.surf.gii"
            Do_cmd wb_command -surface-resample \
                "${tmp}/${hemisphere}h.${surface}.surf.gii" \
                "${dir_conte69}/${surf_id}-fsnative_label-sphere.surf.gii" \
                "${util_surface}/fs_LR-deformed_to-fsaverage.${HEMICAP}.sphere.32k_fs_LR.surf.gii" \
                BARYCENTRIC \
                "${dir_conte69}/${surf_id}-fsLR-32k_space-fsnative_label-${surface}.surf.gii"
            if [[ -f "${dir_conte69}/${surf_id}-fsLR-32k_space-fsnative_label-${surface}.surf.gii" ]]; then ((Nsteps++)); fi
        done
    done
else
    Info "Subject ${idBIDS} has surfaces on fsLR-32k fsnative space"; Nsteps=$((Nsteps+4)); N=$((N+4))
fi

#------------------------------------------------------------------------------#
# Apply transformations to the surface white, midthickness and pial
function appply_surf(){
    # This function takes a surface generated by freesurfer and an affine transformation to the original spaces
    # Removes the offset RAS from freesurfer, register the surface to the native space, and resamples to fsLR-32k
    label=$1
    wb_affine=$2
    for hemi in lh rh; do
        [[ "$hemi" == lh ]] && hemisphere=l || hemisphere=r
        HEMICAP=$(echo $hemisphere | tr [:lower:] [:upper:])
        surf_id=${idBIDS}_hemi-${HEMICAP}_surf
        if [ "${label##*.}" != "gii" ]; then
            in_surf="${tmp}/${hemi}.${label}.surf.gii"
            Do_cmd mris_convert "${dir_subjsurf}/surf/${hemi}.${label}" "${in_surf}"
            out_surf="${dir_conte69}/${surf_id}-fsLR-32k_space-nativepro_label-${label}.surf.gii"
        else
            in_surf="${dir_subjsurf}/surf/${hemi}.${label}"
            out_surf="${dir_conte69}/${surf_id}-fsLR-32k_space-nativepro_label-${label}"
        fi
        # HIppocampal surface in DWI space
        Info "Apply transformations to ${hemi} ${label} surface"
        # remove offset-to-origin from any gifti surface derived from FS
        python "$MICAPIPE"/functions/removeFSoffset.py "${in_surf}" ${tmp}/${label}_no_offset.surf.gii
        # now match target surface to the original fssurf bounding box
        Do_cmd wb_command -surface-match ${tmp}/${label}_no_offset.surf.gii ${dir_conte69}/${surf_id}-fsLR-32k_space-fsnative_label-${label/.surf.gii/}.surf.gii ${tmp}/${label}_fsLR-32k_space-fsnative.surf.gii
        # note: this works because the conte69 surface still has (nearly) exactly the same shape as the fssurface, just different vertices. The more vertices get removed, the more the shape degrades and the exact bounding box may no longer match. With 32k vertices though, the bounding box stays the same to within <0.01mm
        Do_cmd wb_command -surface-apply-affine "${tmp}/${label}_fsLR-32k_space-fsnative.surf.gii" ${wb_affine} "${out_surf}"
    done
}
function from-fsnative_to-fsLR_32k(){
    # Resamples the surface from the nativesurface to fsLR-32k
    surf_fsLR32k=$1
    label=$2
    Hemi=$3
    Do_cmd wb_command -surface-resample \
                "${surf_fsLR32k}" \
                "${dir_conte69}/${idBIDS}_hemi-${Hemi}_surf-fsnative_label-sphere.surf.gii" \
                "${util_surface}/fs_LR-deformed_to-fsaverage.${Hemi}.sphere.32k_fs_LR.surf.gii" \
                BARYCENTRIC \
                "${dir_conte69}/${idBIDS}_hemi-${Hemi}_surf-fsLR-32k_space-nativepro_label-${label}.surf.gii"
}

Nsurf=$(ls ${dir_conte69}/${idBIDS}_hemi-*_surf-fsLR-32k_space-nativepro_label-*.surf.gii 2>/dev/null | wc -l)
if [[ "$Nsurf" -lt 6 ]]; then ((N++))
    Info "Register surfaces to nativepro space"
    if [ ${recon} == "fastsurfer" ]; then
        for hemisphere in l r; do
          HEMICAP=$(echo $hemisphere | tr [:lower:] [:upper:])
          surf_id=${idBIDS}_hemi-${HEMICAP}_surf
          Do_cmd cp "${dir_subjsurf}/surf/${hemisphere}h.midthickness.surf.gii" "${dir_conte69}/${surf_id}-fsnative_space-nativepro_label-midthickness.surf.gii"
          from-fsnative_to-fsLR_32k "${dir_subjsurf}/surf/${hemisphere}h.midthickness.surf.gii" "midthickness" ${HEMICAP}

          Do_cmd mris_convert "${dir_subjsurf}/surf/${hemisphere}h.pial" "${tmp}/${surf_id}-fsnative_space-nativepro_label-pial.surf.gii"
          from-fsnative_to-fsLR_32k "${tmp}/${surf_id}-fsnative_space-nativepro_label-pial.surf.gii" "pial" ${HEMICAP}

          Do_cmd mris_convert "${dir_subjsurf}/surf/${hemisphere}h.white" "${tmp}/${surf_id}-fsnative_space-nativepro_label-white.surf.gii"
          from-fsnative_to-fsLR_32k "${tmp}/${surf_id}-fsnative_space-nativepro_label-white.surf.gii" "white" ${HEMICAP}

        done
    elif [ ${recon} == "freesurfer" ]; then
        # Select the transformation file from ANTs
        affine_xfm="${tmp}/${idBIDS}_from-fsnative_to_nativepro_wb.mat"
        # apply registration to nativepro
        Do_cmd c3d_affine_tool -itk $T1_fsnative_affine -inv -o ${affine_xfm}
        appply_surf midthickness.surf.gii "${affine_xfm}"
        appply_surf pial "${affine_xfm}"
        appply_surf white "${affine_xfm}"
    fi
    Nsurf=$(ls ${dir_conte69}/${idBIDS}_hemi-*_surf-fsLR-32k_space-nativepro_label-*.surf.gii 2>/dev/null | wc -l)
    if [[ "$Nsurf" -eq 6 ]]; then ((Nsteps++)); fi
else
    Info "Subject ${idBIDS} has surfaces on nativepro space"; ((Nsteps++)); ((N++))
fi

# Create json file for post_structural
post_struct_json="${proc_struct}/${idBIDS}_post_structural.json"
json_poststruct "${T1surf}" "${post_struct_json}"

# Running cortical morphology - Requires json_poststruct
Nmorph=$(ls "${dir_maps}/"*thickness* 2>/dev/null | wc -l)
if [[ "$Nmorph" -lt 10 ]]; then ((N++))
    ${MICAPIPE}/functions/03_morphology.sh ${BIDS} ${id} ${out} ${SES} ${nocleanup} ${threads} ${tmpDir} ${PROC}
    Nmorph=$(ls "${dir_maps}/"*thickness* 2>/dev/null | wc -l)
    if [[ "$Nmorph" -eq 10 ]]; then ((Nsteps++)); fi
else
    Info "Subject ${idBIDS} has cortical morphology"; ((Nsteps++)); ((N++))
fi

# -----------------------------------------------------------------------------------------------
# Notification of completition
micapipe_completition_status post_structural
micapipe_procStatus "${id}" "${SES/ses-/}" "post_structural" "${out}/micapipe_processed_sub.csv"
Do_cmd micapipe_procStatus_json "${id}" "${SES/ses-/}" "post_structural" "${module_json}"
cleanup "$tmp" "$nocleanup" "$here"

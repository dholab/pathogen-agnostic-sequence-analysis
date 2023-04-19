#!/usr/bin/env nextflow

nextflow.enable.dsl = 2



// WORKFLOW SPECIFICATION
// --------------------------------------------------------------- //
workflow {
	
	
	// input channels
	ch_reads = Channel
        .fromPath( params.samplesheet )
        .splitCsv( header: true )
        .map { row -> 
            def parent_dir = row.parent_dir?.trim() ?: '/scratch'
            tuple( row.raw_read_label, row.sample_id, parent_dir ) 
        }
    
    ch_ref_seqs = Channel
        .fromPath( params.virus_ref )
    
    ch_contaminants = Channel
        .fromPath( params.contaminants_tar )
	
	// Workflow steps 
    FIND_AND_MERGE_FASTQS (
        ch_reads
    )

    SAMPLE_QC (
        FIND_AND_MERGE_FASTQS.out
    )

    FIND_NTC (
        FIND_AND_MERGE_FASTQS.out
        .map { fasta, id -> fasta }
        .filter { it.getSimpleName().contains("NTC_") }
        .collect()
    )

    CONVERT_TO_FASTA (
        SAMPLE_QC.out
    )

    // DOWNLOAD_CONTAMINANTS ()

    // DECOMPRESS_CONTAMINANTS (
    //     DOWNLOAD_CONTAMINANTS.out
    // )

    DECOMPRESS_CONTAMINANTS (
        ch_contaminants
    )

    REMOVE_CONTAMINANTS (
        CONVERT_TO_FASTA.out,
        DECOMPRESS_CONTAMINANTS.out
    )

    REMOVE_NTC (
        REMOVE_CONTAMINANTS.out,
        FIND_NTC.out
    )

    MAP_TO_REFSEQS (
        REMOVE_NTC.out,
        ch_ref_seqs
    )
	
	
}
// --------------------------------------------------------------- //



// DERIVATIVE PARAMETER SPECIFICATION
// --------------------------------------------------------------- //
// Additional parameters that are derived from parameters set in nextflow.config

// Defining number of cpus to use base on execution environment
if ( workflow.profile == "hpc_cluster" ){
	params.max_cpus = executor.cpus
} else {
	params.max_cpus = params.max_local_cpus
}

// specifying whether to run in low disk mode
if( params.low_disk_mode == true ) {
	params.publishMode = 'symlink'
}
else {
	params.publishMode = 'copy'
}

// Resources subdirectories
params.contam_ref = params.resources + "/contam_ref"

// Results subdirectories
params.raw_reads = params.results + "/1_raw_reads"
params.filtered_reads = params.results + "/2_filtered_reads"
params.fasta_cleaning = params.results + "/3_cleaned_reads"
params.bams = params.results + "/4_alignment_maps"

// --------------------------------------------------------------- //




// PROCESS SPECIFICATION 
// --------------------------------------------------------------- //

process FIND_AND_MERGE_FASTQS {
	
	/*
    Here we determine if the read labels are SRA accessions or 
    local file names. If they are SRA accessions, they will be 
    downloaded and merged automatically from SRA servers. If 
    they are local, they will be located and merged.
    */ 
	
	tag "${sample_id}"
    publishDir params.raw_reads, mode: params.publishMode, overwite: true

    errorStrategy { task.attempt < 4 ? 'retry' : 'ignore' }
    maxRetries 2

    cpus 2
	
	input:
	tuple val(label), val(sample_id), path(parent_dir)
	
	output:
	tuple path("${sample_id}.fastq.gz"), val(sample_id)
	
	script:
    if ( label.startsWith("SRR") )
        """
        prefetch ${label}
        fasterq-dump ${label}/${label}.sra \
        --concatenate-reads --skip-technical --quiet && \
        gzip --no-name ${label}.fastq
        mv ${label}.fastq.gz ${sample_id}.fastq.gz
        rm -rf ${label}/
        rm -rf fasterq.tmp.*
        """
    else
        """
        find `realpath ${parent_dir}` -type f -name ${label}*.fastq.gz > fastq_list.txt
        touch ${sample_id}.fastq
        touch merged_list.txt 
        for i in `cat fastq_list.txt`;
        do
            echo "\$i" >> merged_list.txt 
            zcat \$i >> ${sample_id}.fastq
        done
        if [[ `cat merged_list.txt | wc -l` -eq `cat fastq_list.txt | wc -l` ]]; then
            gzip --no-name ${sample_id}.fastq
        else
            echo "Merging failed."
            exit 1
        fi
        """

}


process SAMPLE_QC {
	
	/*
    Here we run some trimming and quality filtering with the bbmap
    script `reformat.sh` for PacBio or Illumina reads, or cutadapt
    for ONT reads.
    */
	
	tag "${sample_id}"
    publishDir params.filtered_reads, mode: 'copy'
    
    errorStrategy { task.attempt < 4 ? 'retry' : 'ignore' }
    maxRetries 2
	
	input:
	tuple path(fasta), val(sample_id)
	
	output:
	tuple path("*.fastq.gz"), val(sample_id)

    when:
    !sample_id.contains("NTC_")
	
	script:
    if ( params.ont == true )
        """
        reformat.sh in=${fasta} \
        out=${sample_id}_filtered.fastq.gz \
        forcetrimleft=30 forcetrimright2=30 \
        mincalledquality=9 qin=33 minlength=200 
        """
    else if( params.pacbio == true )
        """
        reformat.sh in=${fasta} \
        out=${sample_id}_filtered.fastq.gz \
        forcetrimleft=30 forcetrimright2=30 \
        mincalledquality=9 qin=33 minlength=200 
        """
    else 
        """
        reformat.sh in=${fasta} \
        out=${sample_id}_filtered.fastq.gz \
        forcetrimleft=30 forcetrimright2=30 \
        mincalledquality=9 qin=33 minlength=100 
        """

}


process FIND_NTC {

    /*
    Here we use filenames to identify which of the samples from your
    sequencing run were negative, no-template controls. One of these
    is required for each sequencing run and the associated workflow run.
    We have written this workflow to be run once for each sequencing run,
    and as such, it will produce errors if you put multiple sequencing
    runs worth of samples and controls in the same samplesheet.
    */

    errorStrategy { task.attempt < 4 ? 'retry' : 'ignore' }
    maxRetries 2

    cpus 2

    input:
    path ntc_files

    output:
    path "NTC_*.fasta.gz"

    script:
    """
    find -L . -maxdepth 1 -name "NTC_*" -type f -print > negative_controls.txt
    if [[ `wc -l < negative_controls.txt` -gt 1 ]];
    then
        touch NTC_merged.fastq
        for i in `cat negative_controls.txt`;
        do
            echo "Merging " \$i
            zcat \$i > NTC_merged.fastq && \
            rm \$i
        done
        gzip --no_name NTC_merged.fastq
    fi
    fastq_to_fasta.py ${task.cpus} ${params.seq_batch_size}
    """

}


process CONVERT_TO_FASTA {

    /*
    To save space, FASTQs are converted to FASTAs after QC.
    */

    tag "${sample_id}"
    publishDir params.fasta_cleaning, mode: params.publishMode, overwrite: true
    
    errorStrategy { task.attempt < 4 ? 'retry' : 'ignore' }
    maxRetries 2

    cpus params.max_cpus

    input:
    tuple path(fastq), val(sample_id)
    
    output:
    tuple path("*.fasta.gz"), val(sample_id)

    script:
    """
    fastq_to_fasta.py \
    ${task.cpus} \
    ${params.seq_batch_size}
    """

}


// process DOWNLOAD_CONTAMINANTS {

//     out:
//     path tar

//     script:
//     """
//     curl
//     """

// }


process DECOMPRESS_CONTAMINANTS {

    /*
    A tarball of potential library contaminants, including PhiX adapters,
    host reads, metagenomic contaminants, etc. is included with this workflow.
    To access them, this process decompresses them and sends them to downsream
    processes.
    */

    input:
    path tar

    output:
    path "*.fa.gz"

    script:
    folder_name = tar.getSimpleName()
    """
    tar -xvzf ${tar} && mv ${folder_name}/*.fa.gz ./
    """

}


process REMOVE_CONTAMINANTS {

    /*
    map reads to NVD contaminant databases
    return unmapped reads
    this removes kit-ome and human sequences
    */

    tag "${sample_id}"
    publishDir params.fasta_cleaning, mode: params.publishMode, overwrite: true

    errorStrategy { task.attempt < 4 ? 'retry' : 'ignore' }
    maxRetries 2

    cpus params.max_cpus

    input:
    tuple path(fasta), val(sample_id)
    each path(contaminant_files)

    output:
	tuple path("${sample_id}_contam_removed.fasta.gz"), val(sample_id)

    script:
    """
    ls `realpath *.fa.gz` > contaminant_files.txt

    first=`head -n 1 contaminant_files.txt`
    basename=`basename \$first .fa.gz`
    echo ""
    echo ""
    echo "Now mapping to" \$basename
    echo "-----------------------------"
    echo ""
    minimap2 -ax map-ont --eqx --secondary=no -t ${task.cpus} \$first \
    ${fasta} \
    | reformat.sh unmappedonly=t in=stdin.sam \
    ref=\$first \
    out=tmp.fasta.gz

    for i in `tail -n +2 contaminant_files.txt`; 
    do
        basename=`basename \$i .fa.gz`
        mv tmp.fasta.gz tmp_\$basename.fasta.gz
        echo ""
        echo ""
        echo "Now mapping to" \$basename
        echo "-----------------------------"
        echo ""
        minimap2 -ax map-ont --eqx --secondary=no -t ${task.cpus} \$i \
        tmp_\$basename.fasta.gz \
        | reformat.sh unmappedonly=t overwrite=t in=stdin.sam \
        ref=\$i \
        out=tmp.fasta.gz
    done && \
    mv tmp.fasta.gz ${sample_id}_contam_removed.fasta.gz
    """

}


process REMOVE_NTC {

    /*
    map reads from sample to no-template water control reads
    remove reads that map to sequences found in no template control
    */
    
    tag "${sample_id}"
    publishDir params.fasta_cleaning, mode: params.publishMode, overwrite: true

    errorStrategy 'ignore'

    cpus params.max_cpus

    input:
    tuple path(fasta), val(sample_id)
    each path(ntc)

    output:
	tuple path("${sample_id}_ntc.fasta.gz"), val(sample_id)

    script:
    """
    minimap2 -ax map-ont --eqx --secondary=no -t ${task.cpus} \
    ${ntc} \
    ${fasta} \
    | reformat.sh unmappedonly=t in=stdin.sam \
    ref=${ntc} \
    out=${sample_id}_ntc.fasta.gz
    """

}


process MAP_TO_REFSEQS {
	
	/* 
    This process maps each sample ID's reads to a reference FASTA 
    of 835 human viruses. The resulting BAMs will serve as "hits"
    for which viruses were present in a given air sample.
    */
	
	tag "${sample_id}"
    publishDir params.bams, mode: 'copy', overwite: true

    errorStrategy { task.attempt < 4 ? 'retry' : 'ignore' }
    maxRetries 2
    
    cpus 4
	
	input:
	tuple path(fasta), val(sample_id)
    each path(refseq)
	
	output:
	tuple path("*.bam*"), val(sample_id)
	
	script:
	"""
    minimap2 \
    -ax map-ont \
    ${refseq} \
    ${fasta} \
    --eqx \
    -t 3 \
    | reformat.sh \
    in=stdin.sam \
    ref=${refseq} \
    out=${sample_id}_filtered.bam \
    mappedonly=t
	"""

}


// --------------------------------------------------------------- //